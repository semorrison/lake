/-
Copyright (c) 2021 Mac Malone. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Mac Malone
-/
import Lean.Elab.Frontend
import Lake.DSL.Attributes
import Lake.DSL.Extensions
import Lake.Config.FacetConfig
import Lake.Config.TargetConfig
import Lake.Load.Config

namespace Lake
open Lean System

/-- Main module `Name` of a Lake configuration file. -/
def configModuleName : Name := `lakefile

deriving instance BEq, Hashable for Import

/- Cache for the imported header environment of Lake configuration files. -/
initialize importEnvCache : IO.Ref (Std.HashMap (List Import) Environment) ← IO.mkRef {}

/-- Like `Lean.Elab.processHeader`, but using `importEnvCache`. -/
def processHeader (header : Syntax) (opts : Options) (trustLevel : UInt32)
(inputCtx : Parser.InputContext) : StateT MessageLog IO Environment := do
  try
    let imports := Elab.headerToImports header
    if let some env := (← importEnvCache.get).find? imports then
      return env
    let env ← importModules imports opts trustLevel
    importEnvCache.modify (·.insert imports env)
    return env
  catch e =>
    let pos := inputCtx.fileMap.toPosition <| header.getPos?.getD 0
    modify (·.add { fileName := inputCtx.fileName, data := toString e, pos })
    mkEmptyEnvironment

/-- Like `Lean.Environment.evalConstCheck` but with plain universe-polymorphic `Except`. -/
unsafe def evalConstCheck (env : Environment) (opts : Options) (α) (type : Name) (const : Name) : Except String α :=
  match env.find? const with
  | none => throw s!"unknown constant '{const}'"
  | some info =>
    match info.type with
    | Expr.const c _ =>
      if c != type then
        throwUnexpectedType
      else
        env.evalConst α opts const
    | _ => throwUnexpectedType
where
  throwUnexpectedType : Except String α :=
    throw s!"unexpected type at '{const}', `{type}` expected"

/-- Construct a `NameMap` from the declarations tagged with `attr`. -/
def mkTagMap
(env : Environment) (attr : TagAttribute)
[Monad m]  (f : Name → m α) : m (NameMap α) :=
  attr.ext.getState env |>.foldM (init := {}) fun map declName =>
    return map.insert declName <| ← f declName

/-- Construct a `DNameMap` from the declarations tagged with `attr`. -/
def mkDTagMap
(env : Environment) (attr : TagAttribute)
[Monad m] (f : (n : Name) → m (β n)) : m (DNameMap β) :=
  attr.ext.getState env |>.foldM (init := {}) fun map declName =>
    return map.insert declName <| ← f declName

/-- Unsafe implementation of `loadFromEnv`. -/
unsafe def Package.unsafeLoadFromEnv
(env : Environment) (leanOpts := Options.empty) : LogIO Package := do

  -- Load Configuration
  let pkgDeclName ←
    match packageAttr.ext.getState env |>.toList with
    | [] => error s!"configuration file is missing a `package` declaration"
    | [name] => pure name
    | _ => error s!"configuration file has multiple `package` declarations"
  let config ← IO.ofExcept <|
    evalConstCheck env leanOpts PackageConfig  ``PackageConfig pkgDeclName

  -- Load Dependencies
  let dependencies ← IO.ofExcept <|
    packageDepAttr.ext.getState env |>.foldM (init := #[]) fun arr name => do
      return arr.push <| ← evalConstCheck env leanOpts Dependency ``Dependency name

  -- Load Script, Facet, & Target Configurations
  let scripts ← mkTagMap env scriptAttr fun name => do
    let fn ← IO.ofExcept <| evalConstCheck env leanOpts ScriptFn ``ScriptFn name
    return {fn, doc? := (← findDocString? env name)}
  let leanLibConfigs ← IO.ofExcept <| mkTagMap env leanLibAttr fun name =>
    evalConstCheck env leanOpts LeanLibConfig ``LeanLibConfig name
  let leanExeConfigs ← IO.ofExcept <| mkTagMap env leanExeAttr fun name =>
    evalConstCheck env leanOpts LeanExeConfig ``LeanExeConfig name
  let externLibConfigs ← IO.ofExcept <| mkTagMap env externLibAttr fun name =>
    evalConstCheck env leanOpts ExternLibConfig ``ExternLibConfig name
  let opaqueModuleFacetConfigs ← mkDTagMap env moduleFacetAttr fun name => do
    match evalConstCheck env leanOpts  ModuleFacetDecl ``ModuleFacetDecl name with
    | .ok decl =>
      if h : name = decl.name then
        return OpaqueModuleFacetConfig.mk (h ▸ decl.config)
      else
        error s!"facet was defined as `{decl.name}`, but was registered as `{name}`"
    | .error e => throw <| IO.userError e
  let opaquePackageFacetConfigs ← mkDTagMap env packageFacetAttr fun name => do
    match evalConstCheck env leanOpts  PackageFacetDecl ``PackageFacetDecl name with
    | .ok decl =>
      if h : name = decl.name then
        return OpaquePackageFacetConfig.mk (h ▸ decl.config)
      else
        error s!"facet was defined as `{decl.name}`, but was registered as `{name}`"
    | .error e => throw <| IO.userError e
  let opaqueTargetConfigs ← mkTagMap env targetAttr fun declName =>
    match evalConstCheck env leanOpts TargetConfig ``TargetConfig declName with
    | .ok a => pure <| OpaqueTargetConfig.mk a
    | .error e => throw <| IO.userError e
  let defaultTargets := defaultTargetAttr.ext.getState env |>.fold (·.push ·) #[]

  -- Issue Warnings
  if config.extraDepTarget.isSome then
    logWarning <| "`extraDepTarget` has been deprecated. " ++
      "Try to use a custom target or raise an issue about your use case."
  if leanLibConfigs.isEmpty && leanExeConfigs.isEmpty && config.defaultFacet ≠ .none then
    logWarning <| "Package targets are deprecated. " ++
      "Add a `lean_exe` and/or `lean_lib` default target to the package instead."

  -- Construct the Package
  let some dir := dirExt.getState env
    | error "configuration environment has no package directory set"
  return {
    dir, config, scripts, dependencies,
    leanLibConfigs, leanExeConfigs, externLibConfigs,
    opaqueModuleFacetConfigs, opaquePackageFacetConfigs, opaqueTargetConfigs,
    defaultTargets
  }

/-- Load a `Package` from a configuration environment. -/
@[implementedBy unsafeLoadFromEnv] opaque Package.loadFromEnv
(env : Environment) (leanOpts := Options.empty) : LogIO Package

/--
Load the `Package` located in
the given directory with the given configuration file.
-/
def Package.load (dir : FilePath) (configOpts : NameMap String)
(configFile := dir / defaultConfigFile) (leanOpts := Options.empty) : LogIO Package := do

  -- Read file and initialize environment
  let input ← IO.FS.readFile configFile
  let inputCtx := Parser.mkInputContext input configFile.toString
  let (header, parserState, messages) ← Parser.parseHeader inputCtx
  let (env, messages) ← processHeader header leanOpts 1024 inputCtx messages
  let env := env.setMainModule configModuleName

  -- Configure extensions
  let env := dirExt.setState env dir
  let env := optsExt.setState env configOpts

  -- Elaborate File
  let commandState := Elab.Command.mkState env messages leanOpts
  let s ← Elab.IO.processCommands inputCtx parserState commandState

  -- Report errors
  for msg in s.commandState.messages.toList do
    match msg.severity with
    | MessageSeverity.information => logInfo (← msg.toString)
    | MessageSeverity.warning     => logWarning (← msg.toString)
    | MessageSeverity.error       => logError (← msg.toString)
  if s.commandState.messages.hasErrors then
    error s!"package configuration `{configFile}` has errors"

  -- Load package from the environment
  Package.loadFromEnv s.commandState.env