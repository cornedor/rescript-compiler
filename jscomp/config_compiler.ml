(*
  For Windows, we distribute a prebuilt bsc.exe
  To build on windows, we still need figure out constructing config.ml
  from existing compiler

  For other OSes, we detect
  if there is other compiler installed and the version matches,
  we get the config.ml from existing OCaml compiler and build `whole_compiler`

  Otherwise, we build the compiler shipped with Buckle and use the
  old compiler.ml
*)

[@@@bs.config {no_export}]

external dictOfObj : 'a Js.t -> 'b Js.Dict.t = "%identity"

module Child_process = Node.Child_process
module Process = Node.Process
module Fs = Node.Fs
module Path = Node.Path

let delete_env_var : Process.t -> string -> unit [@bs] = [%raw{|
  function(process, key) { delete process.env[key] }
|}]

let force_opt = function
  | Some a -> a
  | None -> assert false

(* need check which variables exist when we update compiler *)
let map = [%obj {
  _LIBDIR = "standard_library_default";
  _BYTERUN = "standard_runtime";
  _CCOMPTYPE = "ccomp_type";
  _BYTECC = "bytecomp_c_compiler";
  _BYTECCLIBS = "bytecomp_c_libraries";
  _NATIVECC = "native_c_compiler";
  _NATIVECCLIBS = "native_c_libraries";
  _PACKLD = "native_pack_linker";
  _RANLIBCMD = "ranlib";
  _ARCMD = "ar";
  _CC_PROFILE = "cc_profile";

  _MKDLL = "mkdll"; (* undefined *)
  _MKEXE = "mkexe"; (* undefined *)
  _MKMAINDLL = "mkmaindll"; (* undefined TODO= upstream to print it too *)

  _ARCH = "architecture";
  _MODEL = "model";
  _SYSTEM = "system";
  _ASM = "asm";
  _ASM_CFI_SUPPORTED = "asm_cfi_supported"; (* boolean *)
  _WITH_FRAME_POINTERS = "with_frame_pointers"; (* boolean *)
  _EXT_OBJ = "ext_obj";
  _EXT_ASM = "ext_asm";
  _EXT_LIB = "ext_lib";
  _EXT_DLL = "ext_lib";
  _HOST = "host";
  _TARGET = "target";
  _SYSTHREAD_SUPPORT = "systhread_supported"; (* boolean *)
}]

let patch_config jscomp_dir config_map is_windows =
  let whole_compiler_config = Path.join [| jscomp_dir; "bin"; "config_whole_compiler.mlp" |] in
  let whole_compiler_config_output = Path.join [| jscomp_dir; "bin"; "config_whole_compiler.ml" |] in
  let content = Fs.readFileAsUtf8Sync whole_compiler_config in
  let replace_values whole match_ =
    match (match_, is_windows) with
      | ("LIBDIR", true) ->
        {|Filename.concat (Filename.concat (Filename.concat (Filename.dirname Sys.executable_name) "..") "lib") "ocaml"|}
      | ("LIBDIR", false) ->
        let origin_path = Path.join [|jscomp_dir; ".."; "lib"; "ocaml"|] in
        Js.Json.stringify (Js.Json.string origin_path)
      | _ ->
        let map_val = force_opt (Js.Dict.get (dictOfObj map) match_) in
        force_opt (Js.Dict.get config_map map_val)
  in
  let generated = Js.String.replaceByFun1 [%re {|/%%(\w+)%%/g|}] replace_values content in
  Fs.writeFileAsUtf8Sync whole_compiler_config_output generated

let get_config_output is_windows =
  try
    let ocamlc_config = if is_windows
      then "ocamlc.opt.exe -config"
      else "ocamlc.opt -config"
    in
    let config_output = Child_process.execSync ocamlc_config (Child_process.option ~encoding:"utf8" ()) in
    Js.log ("config_output:\n" ^ config_output);

    let keyvalues = Js.String.split "\n" config_output
      |> Js.Array.filter (fun x -> Js.String.length x > 0)
      |> Js.Array.map (fun x ->
        let index = Js.String.indexOf ":" x in
        let key = Js.String.substrAtMost ~from:0 ~length:index x in
        let value = Js.String.substr ~from:(index + 1) x in
        (Js.String.trim key, Js.String.trim value)
      )
    in
    Js.log "keyvalues";
    Js.Array.forEach (fun (key, value) -> Js.log (key ^ ": " ^ value)) keyvalues;

    let accum_pairs = fun acc (key, value) -> Js.Dict.set acc key value; acc in
    Some (Js.Array.reduce accum_pairs (Js.Dict.empty ()) keyvalues)
  with
    _ -> None

let () =
  let dirname = force_opt [%node __dirname] in
  let working_dir = Process.process##cwd () in
  Js.log ("Working dir " ^ working_dir);

  delete_env_var Process.process "OCAMLPARAM" [@bs]; (* stdlib is already compiled using -bin-annot *)
  Js.Dict.set Process.process##env "OCAMLRUNPARAM" "b";

  (* This will not work on Windows
     Windows diestribution relies on env variable OCAMLLIB and CAMLLIB
     delete process.env.OCAMLLIB
     delete process.env.CAMLLIB
  *)
  let is_windows = Process.process##platform = "win32" in
  match get_config_output is_windows with
    | Some config_map ->
      let version = force_opt (Js.Dict.get config_map "version") in
      if Js.String.indexOf "4.02.3" version >= 0
        then patch_config dirname config_map is_windows
        else Process.process##exit 2
    | None ->
      prerr_endline "configuration failure";
      Process.process##exit 2
