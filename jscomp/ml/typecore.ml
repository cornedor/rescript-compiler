(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Typechecking for the core language *)

open Misc
open Asttypes
open Parsetree
open Types
open Typedtree
open Btype
open Ctype

type error =
    Polymorphic_label of Longident.t
  | Constructor_arity_mismatch of Longident.t * int * int
  | Label_mismatch of Longident.t * (type_expr * type_expr) list
  | Pattern_type_clash of (type_expr * type_expr) list
  | Or_pattern_type_clash of Ident.t * (type_expr * type_expr) list
  | Multiply_bound_variable of string
  | Orpat_vars of Ident.t * Ident.t list
  | Expr_type_clash of (type_expr * type_expr) list
  | Apply_non_function of type_expr
  | Apply_wrong_label of arg_label * type_expr
  | Label_multiply_defined of string
  | Labels_missing of string list
  | Label_not_mutable of Longident.t
  | Wrong_name of string * type_expr * string * Path.t * string * string list
  | Name_type_mismatch of
      string * Longident.t * (Path.t * Path.t) * (Path.t * Path.t) list
  | Undefined_method of type_expr * string * string list option
  | Private_type of type_expr
  | Private_label of Longident.t * type_expr

  | Not_subtype of (type_expr * type_expr) list * (type_expr * type_expr) list
  | Coercion_failure of
      type_expr * type_expr * (type_expr * type_expr) list * bool
  | Too_many_arguments of bool * type_expr
  | Abstract_wrong_label of arg_label * type_expr
  | Scoping_let_module of string * type_expr
  | Not_a_variant_type of Longident.t
  | Incoherent_label_order
  | Less_general of string * (type_expr * type_expr) list
  | Modules_not_allowed
  | Cannot_infer_signature
  | Not_a_packed_module of type_expr
  | Recursive_local_constraint of (type_expr * type_expr) list
  | Unexpected_existential
  | Unqualified_gadt_pattern of Path.t * string
  | Invalid_interval
  | Invalid_for_loop_index
  | No_value_clauses
  | Exception_pattern_below_toplevel
  | Inlined_record_escape
  | Inlined_record_expected
  | Unrefuted_pattern of pattern
  | Invalid_extension_constructor_payload
  | Not_an_extension_constructor
  | Literal_overflow of string
  | Unknown_literal of string * char
  | Illegal_letrec_pat
  | Labels_omitted of string list
  | Empty_record_literal
  | Uncurried_arity_mismatch of type_expr * int * int
  | Field_not_optional of string * type_expr
exception Error of Location.t * Env.t * error
exception Error_forward of Location.error

(* Forward declaration, to be filled in by Typemod.type_module *)

let type_module =
  ref ((fun _env _md -> assert false) :
       Env.t -> Parsetree.module_expr -> Typedtree.module_expr)

(* Forward declaration, to be filled in by Typemod.type_open *)

let type_open :
  (?used_slot:bool ref -> override_flag -> Env.t -> Location.t ->
   Longident.t loc -> Path.t * Env.t)
    ref =
  ref (fun ?used_slot:_ _ -> assert false)

(* Forward declaration, to be filled in by Typemod.type_package *)

let type_package =
  ref (fun _ -> assert false)

(* Forward declaration, to be filled in by Typeclass.class_structure *)

(*
  Saving and outputting type information.
  We keep these function names short, because they have to be
  called each time we create a record of type [Typedtree.expression]
  or [Typedtree.pattern] that will end up in the typed AST.
*)
let re node =
  Cmt_format.add_saved_type (Cmt_format.Partial_expression node);
  Stypes.record (Stypes.Ti_expr node);
  node
;;
let rp node =
  Cmt_format.add_saved_type (Cmt_format.Partial_pattern node);
  Stypes.record (Stypes.Ti_pat node);
  node
;;


type recarg =
  | Allowed
  | Required
  | Rejected


let case lhs rhs =
  {c_lhs = lhs; c_guard = None; c_rhs = rhs}

(* Upper approximation of free identifiers on the parse tree *)

let iter_expression f e =

  let rec expr e =
    f e;
    match e.pexp_desc with
    | Pexp_extension _ (* we don't iterate under extension point *)
    | Pexp_ident _
    | Pexp_new _
    | Pexp_constant _ -> ()
    | Pexp_function pel -> List.iter case pel
    | Pexp_fun (_, eo, _, e) -> may expr eo; expr e
    | Pexp_apply (e, lel) -> expr e; List.iter (fun (_, e) -> expr e) lel
    | Pexp_let (_, pel, e) ->  expr e; List.iter binding pel
    | Pexp_match (e, pel)
    | Pexp_try (e, pel) -> expr e; List.iter case pel
    | Pexp_array el
    | Pexp_tuple el -> List.iter expr el
    | Pexp_construct (_, eo)
    | Pexp_variant (_, eo) -> may expr eo
    | Pexp_record (iel, eo) ->
        may expr eo; List.iter (fun (_, e) -> expr e) iel
    | Pexp_open (_, _, e)
    | Pexp_newtype (_, e)
    | Pexp_poly (e, _)
    | Pexp_lazy e
    | Pexp_assert e
    | Pexp_setinstvar (_, e)
    | Pexp_send (e, _)
    | Pexp_constraint (e, _)
    | Pexp_coerce (e, _, _)
    | Pexp_letexception (_, e)
    | Pexp_field (e, _) -> expr e
    | Pexp_while (e1, e2)
    | Pexp_sequence (e1, e2)
    | Pexp_setfield (e1, _, e2) -> expr e1; expr e2
    | Pexp_ifthenelse (e1, e2, eo) -> expr e1; expr e2; may expr eo
    | Pexp_for (_, e1, e2, _, e3) -> expr e1; expr e2; expr e3
    | Pexp_override sel -> List.iter (fun (_, e) -> expr e) sel
    | Pexp_letmodule (_, me, e) -> expr e; module_expr me
    | Pexp_object _ -> assert false
    | Pexp_pack me -> module_expr me
    | Pexp_unreachable -> ()

  and case {pc_lhs = _; pc_guard; pc_rhs} =
    may expr pc_guard;
    expr pc_rhs

  and binding x =
    expr x.pvb_expr

  and module_expr me =
    match me.pmod_desc with
    | Pmod_extension _
    | Pmod_ident _ -> ()
    | Pmod_structure str -> List.iter structure_item str
    | Pmod_constraint (me, _)
    | Pmod_functor (_, _, me) -> module_expr me
    | Pmod_apply (me1, me2) -> module_expr me1; module_expr me2
    | Pmod_unpack e -> expr e


  and structure_item str =
    match str.pstr_desc with
    | Pstr_eval (e, _) -> expr e
    | Pstr_value (_, pel) -> List.iter binding pel
    | Pstr_primitive _
    | Pstr_type _
    | Pstr_typext _
    | Pstr_exception _
    | Pstr_modtype _
    | Pstr_open _
    | Pstr_class_type _
    | Pstr_attribute _
    | Pstr_extension _ -> ()
    | Pstr_include {pincl_mod = me}
    | Pstr_module {pmb_expr = me} -> module_expr me
    | Pstr_recmodule l -> List.iter (fun x -> module_expr x.pmb_expr) l
    | Pstr_class () -> ()




  in
  expr e


let all_idents_cases el =
  let idents = Hashtbl.create 8 in
  let f = function
    | {pexp_desc=Pexp_ident { txt = Longident.Lident id; _ }; _} ->
        Hashtbl.replace idents id ()
    | _ -> ()
  in
  List.iter
    (fun cp ->
      may (iter_expression f) cp.pc_guard;
      iter_expression f cp.pc_rhs
    )
    el;
  Hashtbl.fold (fun x () rest -> x :: rest) idents []


(* Typing of constants *)

let type_constant = function
    Const_int _ -> instance_def Predef.type_int
  | Const_char _ -> instance_def Predef.type_char
  | Const_string _ -> instance_def Predef.type_string
  | Const_float _ -> instance_def Predef.type_float
  | Const_int64 _ -> instance_def Predef.type_int64
  | Const_int32 _ 
  | Const_nativeint _ ->  assert false

let constant : Parsetree.constant -> (Asttypes.constant, error) result =
  function
  | Pconst_integer (i,None) ->
     begin
       try Ok (Const_int (Misc.Int_literal_converter.int i))
       with Failure _ -> Error (Literal_overflow "int")
     end
  | Pconst_integer (i,Some 'l') ->
     begin
       try Ok (Const_int32 (Misc.Int_literal_converter.int32 i))
       with Failure _ -> Error (Literal_overflow "int32")
     end
  | Pconst_integer (i,Some 'L') ->
     begin
       try Ok (Const_int64 (Misc.Int_literal_converter.int64 i))
       with Failure _ -> Error (Literal_overflow "int64")
     end
  | Pconst_integer (i,Some 'n') ->
     begin
       try Ok (Const_nativeint (Misc.Int_literal_converter.nativeint i))
       with Failure _ -> Error (Literal_overflow "nativeint")
     end
  | Pconst_integer (i,Some c) -> Error (Unknown_literal (i, c))
  | Pconst_char c -> Ok (Const_char c)
  | Pconst_string (s,d) -> Ok (Const_string (s,d))
  | Pconst_float (f,None)-> Ok (Const_float f)
  | Pconst_float (f,Some c) -> Error (Unknown_literal (f, c))

let constant_or_raise env loc cst =
  match constant cst with
  | Ok c -> c
  | Error err -> raise (Error (loc, env, err))

(* Specific version of type_option, using newty rather than newgenty *)

let type_option ty =
  newty (Tconstr(Predef.path_option,[ty], ref Mnil))

let mkexp exp_desc exp_type exp_loc exp_env =
  { exp_desc; exp_type; exp_loc; exp_env; exp_extra = []; exp_attributes = [] }

let option_none ty loc =
  let lid = Longident.Lident "None"
  and env = Env.initial_safe_string in
  let cnone = Env.lookup_constructor lid env in
  mkexp (Texp_construct(mknoloc lid, cnone, [])) ty loc env

let option_some texp =
  let lid = Longident.Lident "Some" in
  let csome = Env.lookup_constructor lid Env.initial_safe_string in
  mkexp ( Texp_construct(mknoloc lid , csome, [texp]) )
    (type_option texp.exp_type) texp.exp_loc texp.exp_env

let extract_option_type env ty =
  match expand_head env ty with {desc = Tconstr(path, [ty], _)}
    when Path.same path Predef.path_option -> ty
  | _ -> assert false

let extract_concrete_record env ty =
  match extract_concrete_typedecl env ty with
    (p0, p, {type_kind=Type_record (fields, repr)}) -> (p0, p, fields, repr)
  | _ -> raise Not_found

let extract_concrete_variant env ty =
  match extract_concrete_typedecl env ty with
    (p0, p, {type_kind=Type_variant cstrs}) -> (p0, p, cstrs)
  | (p0, p, {type_kind=Type_open}) -> (p0, p, [])
  | _ -> raise Not_found

let label_is_optional ld =
  match ld.lbl_repres with
  | Record_optional_labels lbls -> Ext_list.mem_string lbls ld.lbl_name
  | Record_inlined {optional_labels} -> Ext_list.mem_string optional_labels ld.lbl_name
  | _ -> false

let check_optional_attr env ld attrs loc =
  let check_redundant () =
    if not (label_is_optional ld) then
      raise (Error (loc, env, Field_not_optional (ld.lbl_name, ld.lbl_res)));
    true in 
  Ext_list.exists attrs (fun ({txt}, _) ->
    txt = "res.optional" && check_redundant ())

(* unification inside type_pat*)
let unify_pat_types loc env ty ty' =
  try
    unify env ty ty'
  with
    Unify trace ->
      raise(Error(loc, env, Pattern_type_clash(trace)))
  | Tags(l1,l2) ->
      raise(Typetexp.Error(loc, env, Typetexp.Variant_tags (l1, l2)))

(* unification inside type_exp and type_expect *)
let unify_exp_types loc env ty expected_ty =
  (* Format.eprintf "@[%a@ %a@]@." Printtyp.raw_type_expr exp.exp_type
    Printtyp.raw_type_expr expected_ty; *)
  try
    unify env ty expected_ty
  with
    Unify trace ->
      raise(Error(loc, env, Expr_type_clash(trace)))
  | Tags(l1,l2) ->
      raise(Typetexp.Error(loc, env, Typetexp.Variant_tags (l1, l2)))

(* level at which to create the local type declarations *)
let newtype_level = ref None
let get_newtype_level () =
  match !newtype_level with
    Some y -> y
  | None -> assert false

let unify_pat_types_gadt loc env ty ty' =
  let newtype_level =
    match !newtype_level with
    | None -> assert false
    | Some x -> x
  in
  try
    unify_gadt ~newtype_level env ty ty'
  with
    Unify trace ->
      raise(Error(loc, !env, Pattern_type_clash(trace)))
  | Tags(l1,l2) ->
      raise(Typetexp.Error(loc, !env, Typetexp.Variant_tags (l1, l2)))
  | Unification_recursive_abbrev trace ->
      raise(Error(loc, !env, Recursive_local_constraint trace))


(* Creating new conjunctive types is not allowed when typing patterns *)

let unify_pat env pat expected_ty =
  unify_pat_types pat.pat_loc env pat.pat_type expected_ty

(* make all Reither present in open variants *)
let finalize_variant pat =
  match pat.pat_desc with
    Tpat_variant(tag, opat, r) ->
      let row =
        match expand_head pat.pat_env pat.pat_type with
          {desc = Tvariant row} -> r := row; row_repr row
        | _ -> assert false
      in
      begin match row_field tag row with
      | Rabsent -> () (* assert false *)
      | Reither (true, [], _, e) when not row.row_closed ->
          set_row_field e (Rpresent None)
      | Reither (false, ty::tl, _, e) when not row.row_closed ->
          set_row_field e (Rpresent (Some ty));
          begin match opat with None -> assert false
          | Some pat -> List.iter (unify_pat pat.pat_env pat) (ty::tl)
          end
      | Reither (c, _l, true, e) when not (row_fixed row) ->
          set_row_field e (Reither (c, [], false, ref None))
      | _ -> ()
      end;
      (* Force check of well-formedness   WHY? *)
      (* unify_pat pat.pat_env pat
        (newty(Tvariant{row_fields=[]; row_more=newvar(); row_closed=false;
                        row_bound=(); row_fixed=false; row_name=None})); *)
  | _ -> ()

let rec iter_pattern f p =
  f p;
  iter_pattern_desc (iter_pattern f) p.pat_desc

let has_variants p =
  try
    iter_pattern (function {pat_desc=Tpat_variant _} -> raise Exit | _ -> ())
      p;
    false
  with Exit ->
    true


(* pattern environment *)
let pattern_variables = ref ([] :
 (Ident.t * type_expr * string loc * Location.t * bool (* as-variable *)) list)
let pattern_force = ref ([] : (unit -> unit) list)
let pattern_scope = ref (None : Annot.ident option);;
let allow_modules = ref false
let module_variables = ref ([] : (string loc * Location.t) list)
let reset_pattern scope allow =
  pattern_variables := [];
  pattern_force := [];
  pattern_scope := scope;
  allow_modules := allow;
  module_variables := [];
;;

let enter_variable ?(is_module=false) ?(is_as_variable=false) loc name ty =
  if List.exists (fun (id, _, _, _, _) -> Ident.name id = name.txt)
      !pattern_variables
  then raise(Error(loc, Env.empty, Multiply_bound_variable name.txt));
  let id = Ident.create name.txt in
  pattern_variables :=
    (id, ty, name, loc, is_as_variable) :: !pattern_variables;
  if is_module then begin
    (* Note: unpack patterns enter a variable of the same name *)
    if not !allow_modules then
      raise (Error (loc, Env.empty, Modules_not_allowed));
    module_variables := (name, loc) :: !module_variables
  end else
    (* moved to genannot *)
    may (fun s -> Stypes.record (Stypes.An_ident (name.loc, name.txt, s)))
        !pattern_scope;
  id

let sort_pattern_variables vs =
  List.sort
    (fun (x,_,_,_,_) (y,_,_,_,_) ->
      compare (Ident.name x) (Ident.name y))
    vs

let enter_orpat_variables loc env  p1_vs p2_vs =
  (* unify_vars operate on sorted lists *)

  let p1_vs = sort_pattern_variables p1_vs
  and p2_vs = sort_pattern_variables p2_vs in

  let rec unify_vars p1_vs p2_vs =
    let vars vs = List.map (fun (x,_t,_,_l,_a) -> x) vs in
    match p1_vs, p2_vs with
      | (x1,t1,_,_l1,_a1)::rem1, (x2,t2,_,_l2,_a2)::rem2
        when Ident.equal x1 x2 ->
          if x1==x2 then
            unify_vars rem1 rem2
          else begin
            begin try
              unify env t1 t2
            with
            | Unify trace ->
                raise(Error(loc, env, Or_pattern_type_clash(x1, trace)))
            end;
          (x2,x1)::unify_vars rem1 rem2
          end
      | [],[] -> []
      | (x,_,_,_,_)::_, [] -> raise (Error (loc, env, Orpat_vars (x, [])))
      | [],(y,_,_,_,_)::_  -> raise (Error (loc, env, Orpat_vars (y, [])))
      | (x,_,_,_,_)::_, (y,_,_,_,_)::_ ->
          let err =
            if Ident.name x < Ident.name y
            then Orpat_vars (x, vars p2_vs)
            else Orpat_vars (y, vars p1_vs) in
          raise (Error (loc, env, err)) in
  unify_vars p1_vs p2_vs

let rec build_as_type env p =
  match p.pat_desc with
    Tpat_alias(p1,_, _) -> build_as_type env p1
  | Tpat_tuple pl ->
      let tyl = List.map (build_as_type env) pl in
      newty (Ttuple tyl)
  | Tpat_construct(_, cstr, pl) ->
      let keep = cstr.cstr_private = Private || cstr.cstr_existentials <> [] in
      if keep then p.pat_type else
      let tyl = List.map (build_as_type env) pl in
      let ty_args, ty_res = instance_constructor cstr in
      List.iter2 (fun (p,ty) -> unify_pat env {p with pat_type = ty})
        (List.combine pl tyl) ty_args;
      ty_res
  | Tpat_variant(l, p', _) ->
      let ty = may_map (build_as_type env) p' in
      newty (Tvariant{row_fields=[l, Rpresent ty]; row_more=newvar();
                      row_bound=(); row_name=None;
                      row_fixed=false; row_closed=false})
  | Tpat_record (lpl,_) ->
      let lbl = snd3 (List.hd lpl) in
      if lbl.lbl_private = Private then p.pat_type else
      let ty = newvar () in
      let ppl = List.map (fun (_, l, p) -> l.lbl_pos, p) lpl in
      let do_label lbl =
        let _, ty_arg, ty_res = instance_label false lbl in
        unify_pat env {p with pat_type = ty} ty_res;
        let refinable =
          lbl.lbl_mut = Immutable && List.mem_assoc lbl.lbl_pos ppl &&
          match (repr lbl.lbl_arg).desc with Tpoly _ -> false | _ -> true in
        if refinable then begin
          let arg = List.assoc lbl.lbl_pos ppl in
          unify_pat env {arg with pat_type = build_as_type env arg} ty_arg
        end else begin
          let _, ty_arg', ty_res' = instance_label false lbl in
          unify env ty_arg ty_arg';
          unify_pat env p ty_res'
        end in
      Array.iter do_label lbl.lbl_all;
      ty
  | Tpat_or(p1, p2, row) ->
      begin match row with
        None ->
          let ty1 = build_as_type env p1 and ty2 = build_as_type env p2 in
          unify_pat env {p2 with pat_type = ty2} ty1;
          ty1
      | Some row ->
          let row = row_repr row in
          newty (Tvariant{row with row_closed=false; row_more=newvar()})
      end
  | Tpat_any | Tpat_var _ | Tpat_constant _
  | Tpat_array _ | Tpat_lazy _ -> p.pat_type

let build_or_pat env loc lid =
  let path, decl = Typetexp.find_type env lid.loc lid.txt
  in
  let tyl = List.map (fun _ -> newvar()) decl.type_params in
  let row0 =
    let ty = expand_head env (newty(Tconstr(path, tyl, ref Mnil))) in
    match ty.desc with
      Tvariant row when static_row row -> row
    | _ -> raise(Error(lid.loc, env, Not_a_variant_type lid.txt))
  in
  let pats, fields =
    List.fold_left
      (fun (pats,fields) (l,f) ->
        match row_field_repr f with
          Rpresent None ->
            (l,None) :: pats,
            (l, Reither(true,[], true, ref None)) :: fields
        | Rpresent (Some ty) ->
            (l, Some {pat_desc=Tpat_any; pat_loc=Location.none; pat_env=env;
                      pat_type=ty; pat_extra=[]; pat_attributes=[]})
            :: pats,
            (l, Reither(false, [ty], true, ref None)) :: fields
        | _ -> pats, fields)
      ([],[]) (row_repr row0).row_fields in
  let row =
    { row_fields = List.rev fields; row_more = newvar(); row_bound = ();
      row_closed = false; row_fixed = false; row_name = Some (path, tyl) }
  in
  let ty = newty (Tvariant row) in
  let gloc = {loc with Location.loc_ghost=true} in
  let row' = ref {row with row_more=newvar()} in
  let pats =
    List.map
      (fun (l,p) ->
        {pat_desc=Tpat_variant(l,p,row'); pat_loc=gloc;
         pat_env=env; pat_type=ty; pat_extra=[]; pat_attributes=[]})
      pats
  in
  match pats with
    [] -> raise(Error(lid.loc, env, Not_a_variant_type lid.txt))
  | pat :: pats ->
      let r =
        List.fold_left
          (fun pat pat0 ->
            {pat_desc=Tpat_or(pat0,pat,Some row0); pat_extra=[];
             pat_loc=gloc; pat_env=env; pat_type=ty; pat_attributes=[]})
          pat pats in
      (path, rp { r with pat_loc = loc },ty)

(* Type paths *)

let rec expand_path env p =
  let decl =
    try Some (Env.find_type p env) with Not_found -> None
  in
  match decl with
    Some {type_manifest = Some ty} ->
      begin match repr ty with
        {desc=Tconstr(p,_,_)} -> expand_path env p
      | _ -> p
         (* PR#6394: recursive module may introduce incoherent manifest *)
      end
  | _ ->
      let p' = Env.normalize_path None env p in
      if Path.same p p' then p else expand_path env p'

let compare_type_path env tpath1 tpath2 =
  Path.same (expand_path env tpath1) (expand_path env tpath2)

(* Records *)
let label_of_kind kind =
  if kind = "record" then "field" else "constructor"

module NameChoice(Name : sig
  type t
  val type_kind: string
  val get_name: t -> string
  val get_type: t -> type_expr
  val get_descrs: Env.type_descriptions -> t list
  val unbound_name_error: Env.t -> Longident.t loc -> 'a

end) = struct
  open Name

  let get_type_path d =
    match (repr (get_type d)).desc with
    | Tconstr(p, _, _) -> p
    | _ -> assert false

  let lookup_from_type env tpath lid =
    let descrs = get_descrs (Env.find_type_descrs tpath env) in
    Env.mark_type_used env (Path.last tpath) (Env.find_type tpath env);
    match lid.txt with
      Longident.Lident s -> begin
        try
          List.find (fun nd -> get_name nd = s) descrs
        with Not_found ->
          let names = List.map get_name descrs in
          raise (Error (lid.loc, env,
                        Wrong_name ("", newvar (), type_kind, tpath, s, names)))
      end
    | _ -> raise Not_found

  let rec unique eq acc = function
      [] -> List.rev acc
    | x :: rem ->
        if List.exists (eq x) acc then unique eq acc rem
        else unique eq (x :: acc) rem

  let ambiguous_types env lbl others =
    let tpath = get_type_path lbl in
    let others =
      List.map (fun (lbl, _) -> get_type_path lbl) others in
    let tpaths = unique (compare_type_path env) [tpath] others in
    match tpaths with
      [_] -> []
    | _ -> List.map Printtyp.string_of_path tpaths

  let disambiguate_by_type env tpath lbls =
    let check_type (lbl, _) =
      let lbl_tpath = get_type_path lbl in
      compare_type_path env tpath lbl_tpath
    in
    List.find check_type lbls

  let disambiguate ?(warn=Location.prerr_warning) ?(check_lk=fun _ _ -> ())
      ?scope lid env opath lbls =
    let scope = match scope with None -> lbls | Some l -> l in
    let lbl = match opath with
      None ->
        begin match lbls with
          [] -> unbound_name_error env lid
        | (lbl, use) :: rest ->
            use ();
            let paths = ambiguous_types env lbl rest in
            if paths <> [] then
              warn lid.loc
                (Warnings.Ambiguous_name ([Longident.last lid.txt],
                                          paths, false));
            lbl
        end
    | Some(tpath0, tpath) ->
        try
          let lbl, use = disambiguate_by_type env tpath scope in
          use ();
          lbl
        with Not_found -> try
          let lbl = lookup_from_type env tpath lid in
          check_lk tpath lbl;
          lbl
        with Not_found ->
          if lbls = [] then unbound_name_error env lid else
          let tp = (tpath0, expand_path env tpath) in
          let tpl =
            List.map
              (fun (lbl, _) ->
                let tp0 = get_type_path lbl in
                let tp = expand_path env tp0 in
                  (tp0, tp))
              lbls
          in
          raise (Error (lid.loc, env,
                        Name_type_mismatch (type_kind, lid.txt, tp, tpl)))
    in
    lbl
end

let wrap_disambiguate kind ty f x =
  try f x with Error (loc, env, Wrong_name ("",_,tk,tp,name,valid_names)) ->
    raise (Error (loc, env, Wrong_name (kind,ty,tk,tp,name,valid_names)))

module Label = NameChoice (struct
  type t = label_description
  let type_kind = "record"
  let get_name lbl = lbl.lbl_name
  let get_type lbl = lbl.lbl_res
  let get_descrs = snd
  let unbound_name_error = Typetexp.unbound_label_error
end)

let disambiguate_label_by_ids keep closed ids labels =
  let check_ids (lbl, _) =
    let lbls = Hashtbl.create 8 in
    Array.iter (fun lbl -> Hashtbl.add lbls lbl.lbl_name ()) lbl.lbl_all;
    List.for_all (Hashtbl.mem lbls) ids
  and check_closed (lbl, _) =
    (not closed || List.length ids = Array.length lbl.lbl_all)
  in
  let labels' = Ext_list.filter labels check_ids in
  if keep && labels' = [] then (false, labels) else
  let labels'' = Ext_list.filter labels' check_closed in
  if keep && labels'' = [] then (false, labels') else (true, labels'')

(* Only issue warnings once per record constructor/pattern *)
let disambiguate_lid_a_list loc closed env opath lid_a_list =
  let ids = List.map (fun (lid, _) -> Longident.last lid.txt) lid_a_list in
  let w_amb = ref [] in
  let warn loc msg =
    let open Warnings in
    match msg with

    | Ambiguous_name([s], l, _) -> w_amb := (s, l) :: !w_amb
    | _ -> Location.prerr_warning loc msg
  in
  let process_label lid =
    (* Strategy for each field:
       * collect all the labels in scope for that name
       * if the type is known and principal, just eventually warn
         if the real label was not in scope
       * fail if there is no known type and no label found
       * otherwise use other fields to reduce the list of candidates
       * if there is no known type reduce it incrementally, so that
         there is still at least one candidate (for error message)
       * if the reduced list is valid, call Label.disambiguate
     *)
    let scope = Typetexp.find_all_labels env lid.loc lid.txt in
    if opath = None && scope = [] then
      Typetexp.unbound_label_error env lid;
    let (ok, labels) =
      match opath with
        Some (_, _) -> (true, scope) (* disambiguate only checks scope *)
      | _  -> disambiguate_label_by_ids (opath=None) closed ids scope
    in
    if ok then Label.disambiguate lid env opath labels ~warn ~scope
          else fst (List.hd labels) (* will fail later *)
  in
  let lbl_a_list =
    List.map (fun (lid,a) -> lid, process_label lid, a) lid_a_list in
  begin
    match List.rev !w_amb with
      (_,types)::_ as amb ->
        let paths =
          List.map (fun (_,lbl,_) -> Label.get_type_path lbl) lbl_a_list in
        let path = List.hd paths in
        if List.for_all (compare_type_path env path) (List.tl paths) then
          Location.prerr_warning loc
            (Warnings.Ambiguous_name (List.map fst amb, types, true))
        else
          List.iter
            (fun (s,l) -> Location.prerr_warning loc
                (Warnings.Ambiguous_name ([s],l,false)))
            amb
    | _ -> ()
  end;
  lbl_a_list

let rec find_record_qual = function
  | [] -> None
  | ({ txt = Longident.Ldot (modname, _) }, _) :: _ -> Some modname
  | _ :: rest -> find_record_qual rest

let map_fold_cont f xs k =
  List.fold_right (fun x k ys -> f x (fun y -> k (y :: ys)))
    xs (fun ys -> k (List.rev ys)) []

let type_label_a_list ?labels loc closed env type_lbl_a opath lid_a_list k =
  let lbl_a_list =
    match lid_a_list, labels with
      ({txt=Longident.Lident s}, _)::_, Some labels when Hashtbl.mem labels s ->
        (* Special case for rebuilt syntax trees *)
        List.map
          (function lid, a -> match lid.txt with
            Longident.Lident s -> lid, Hashtbl.find labels s, a
          | _ -> assert false)
          lid_a_list
    | _ ->
        let lid_a_list =
          match find_record_qual lid_a_list with
            None -> lid_a_list
          | Some modname ->
              List.map
                (fun (lid, a as lid_a) ->
                  match lid.txt with Longident.Lident s ->
                    {lid with txt=Longident.Ldot (modname, s)}, a
                  | _ -> lid_a)
                lid_a_list
        in
        disambiguate_lid_a_list loc closed env opath lid_a_list
  in
  (* Invariant: records are sorted in the typed tree *)
  let lbl_a_list =
    List.sort
      (fun (_,lbl1,_) (_,lbl2,_) -> compare lbl1.lbl_pos lbl2.lbl_pos)
      lbl_a_list
  in
  map_fold_cont type_lbl_a lbl_a_list k
;;

(* Checks over the labels mentioned in a record pattern:
   no duplicate definitions (error); properly closed (warning) *)

let check_recordpat_labels loc lbl_pat_list closed =
  match lbl_pat_list with
  | [] -> ()                            (* should not happen *)
  | (_, label1, _) :: _ ->
      let all = label1.lbl_all in
      let defined = Array.make (Array.length all) false in
      let check_defined (_, label, _) =
        if defined.(label.lbl_pos)
        then raise(Error(loc, Env.empty, Label_multiply_defined label.lbl_name))
        else defined.(label.lbl_pos) <- true in
      List.iter check_defined lbl_pat_list;
      if closed = Closed
      && Warnings.is_active (Warnings.Non_closed_record_pattern "")
      then begin
        let undefined = ref [] in
        for i = 0 to Array.length all - 1 do
          if not defined.(i) then undefined := all.(i).lbl_name :: !undefined
        done;
        if !undefined <> [] then begin
          let u = String.concat ", " (List.rev !undefined) in
          Location.prerr_warning loc (Warnings.Non_closed_record_pattern u)
        end
      end

(* Constructors *)

module Constructor = NameChoice (struct
  type t = constructor_description
  let type_kind = "variant"
  let get_name cstr = cstr.cstr_name
  let get_type cstr = cstr.cstr_res
  let get_descrs = fst
  let unbound_name_error = Typetexp.unbound_constructor_error
end)

(* unification of a type with a tconstr with
   freshly created arguments *)
let unify_head_only loc env ty constr =
  let (_, ty_res) = instance_constructor constr in
  match (repr ty_res).desc with
  | Tconstr(p,args,m) ->
      ty_res.desc <- Tconstr(p,List.map (fun _ -> newvar ()) args,m);
      enforce_constraints env ty_res;
      unify_pat_types loc env ty_res ty
  | _ -> assert false

(* Typing of patterns *)

(* Remember current state for backtracking.
   No variable information, as we only backtrack on
   patterns without variables (cf. assert statements). *)
type state =
 { snapshot: Btype.snapshot;
   levels: Ctype.levels;
   env: Env.t; }
let save_state env =
  { snapshot = Btype.snapshot ();
    levels = Ctype.save_levels ();
    env = !env; }
let set_state s env =
  Btype.backtrack s.snapshot;
  Ctype.set_levels s.levels;
  env := s.env

(* type_pat does not generate local constraints inside or patterns *)
type type_pat_mode =
  | Normal
  | Splitting_or   (* splitting an or-pattern *)
  | Inside_or      (* inside a non-split or-pattern *)
  | Split_or       (* always split or-patterns *)

exception Need_backtrack

(* type_pat propagates the expected type as well as maps for
   constructors and labels.
   Unification may update the typing environment. *)
(* constrs <> None => called from parmatch: backtrack on or-patterns
   explode > 0 => explode Ppat_any for gadts *)
let rec type_pat ~constrs ~labels ~no_existentials ~mode ~explode ~env
    sp expected_ty k =
  Builtin_attributes.warning_scope sp.ppat_attributes
    (fun () ->
       type_pat_aux ~constrs ~labels ~no_existentials ~mode ~explode ~env
         sp expected_ty k
    )

and type_pat_aux ~constrs ~labels ~no_existentials ~mode ~explode ~env
    sp expected_ty k =
  let mode' = if mode = Splitting_or then Normal else mode in
  let type_pat ?(constrs=constrs) ?(labels=labels) ?(mode=mode')
      ?(explode=explode) ?(env=env) =
    type_pat ~constrs ~labels ~no_existentials ~mode ~explode ~env in
  let loc = sp.ppat_loc in
  let rp k x : pattern = if constrs = None then k (rp x) else k x in
  match sp.ppat_desc with
    Ppat_any ->
      let k' d = rp k {
        pat_desc = d;
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env }
      in
      if explode > 0 then
        let (sp, constrs, labels) = Parmatch.ppat_of_type !env expected_ty in
        if sp.ppat_desc = Parsetree.Ppat_any then k' Tpat_any else
        if mode = Inside_or then raise Need_backtrack else
        let explode =
          match sp.ppat_desc with
            Parsetree.Ppat_or _ -> explode - 5
          | _ -> explode - 1
        in
        type_pat ~constrs:(Some constrs) ~labels:(Some labels)
          ~explode sp expected_ty k
      else k' Tpat_any
  | Ppat_var name ->
      let id = (* PR#7330 *)
        if name.txt = "*extension*" then Ident.create name.txt else
        enter_variable loc name expected_ty
      in
      rp k {
        pat_desc = Tpat_var (id, name);
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env }
  | Ppat_unpack name ->
      assert (constrs = None);
      let id = enter_variable loc name expected_ty ~is_module:true in
      rp k {
        pat_desc = Tpat_var (id, name);
        pat_loc = sp.ppat_loc;
        pat_extra=[Tpat_unpack, loc, sp.ppat_attributes];
        pat_type = expected_ty;
        pat_attributes = [];
        pat_env = !env }
  | Ppat_constraint({ppat_desc=Ppat_var name; ppat_loc=lloc},
                    ({ptyp_desc=Ptyp_poly _} as sty)) ->
      (* explicitly polymorphic type *)
      assert (constrs = None);
      let cty, force = Typetexp.transl_simple_type_delayed !env sty in
      let ty = cty.ctyp_type in
      unify_pat_types lloc !env ty expected_ty;
      pattern_force := force :: !pattern_force;
      begin match ty.desc with
      | Tpoly (body, tyl) ->
          begin_def ();
          let _, ty' = instance_poly ~keep_names:true false tyl body in
          end_def ();
          generalize ty';
          let id = enter_variable lloc name ty' in
          rp k {
            pat_desc = Tpat_var (id, name);
            pat_loc = lloc;
            pat_extra = [Tpat_constraint cty, loc, sp.ppat_attributes];
            pat_type = ty;
            pat_attributes = [];
            pat_env = !env
          }
      | _ -> assert false
      end
  | Ppat_alias(sq, name) ->
      assert (constrs = None);
      type_pat sq expected_ty (fun q ->
        begin_def ();
        let ty_var = build_as_type !env q in
        end_def ();
        generalize ty_var;
        let id = enter_variable ~is_as_variable:true loc name ty_var in
        rp k {
          pat_desc = Tpat_alias(q, id, name);
          pat_loc = loc; pat_extra=[];
          pat_type = q.pat_type;
          pat_attributes = sp.ppat_attributes;
          pat_env = !env })
  | Ppat_constant cst ->
      let cst = constant_or_raise !env loc cst in
      unify_pat_types loc !env (type_constant cst) expected_ty;
      rp k {
        pat_desc = Tpat_constant cst;
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env }
  | Ppat_interval (Pconst_char c1, Pconst_char c2) ->
      let open Ast_helper.Pat in
      let gloc = {loc with Location.loc_ghost=true} in
      let rec loop c1 c2 =
        if c1 = c2 then constant ~loc:gloc (Pconst_char c1)
        else
          or_ ~loc:gloc
            (constant ~loc:gloc (Pconst_char c1))
            (loop (c1 + 1) c2)
      in
      let p = if c1 <= c2 then loop c1 c2 else loop c2 c1 in
      let p = {p with ppat_loc=loc} in
      type_pat ~explode:0 p expected_ty k
        (* TODO: record 'extra' to remember about interval *)
  | Ppat_interval _ ->
      raise (Error (loc, !env, Invalid_interval))
  | Ppat_tuple spl ->
      assert (List.length spl >= 2);
      let spl_ann = List.map (fun p -> (p,newvar ())) spl in
      let ty = newty (Ttuple(List.map snd spl_ann)) in
      unify_pat_types loc !env ty expected_ty;
      map_fold_cont (fun (p,t) -> type_pat p t) spl_ann (fun pl ->
        rp k {
        pat_desc = Tpat_tuple pl;
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env })
  | Ppat_construct(lid, sarg) ->
      let opath =
        try
          let (p0, p, _) = extract_concrete_variant !env expected_ty in
            Some (p0, p)
        with Not_found -> None
      in
      let candidates =
        match lid.txt, constrs with
          Longident.Lident s, Some constrs when Hashtbl.mem constrs s ->
            [Hashtbl.find constrs s, (fun () -> ())]
        | _ ->  Typetexp.find_all_constructors !env lid.loc lid.txt
      in
      let check_lk tpath constr =
        if constr.cstr_generalized then
          raise (Error (lid.loc, !env,
                        Unqualified_gadt_pattern (tpath, constr.cstr_name)))
      in
      let constr =
        wrap_disambiguate "This variant pattern is expected to have" expected_ty
          (Constructor.disambiguate lid !env opath ~check_lk) candidates
      in
      if constr.cstr_generalized && constrs <> None && mode = Inside_or
      then raise Need_backtrack;
      Env.mark_constructor Env.Pattern !env (Longident.last lid.txt) constr;
      Builtin_attributes.check_deprecated loc constr.cstr_attributes
        constr.cstr_name;
      if no_existentials && constr.cstr_existentials <> [] then
        raise (Error (loc, !env, Unexpected_existential));
      (* if constructor is gadt, we must verify that the expected type has the
         correct head *)
      if constr.cstr_generalized then
        unify_head_only loc !env expected_ty constr;
      let sargs =
        match sarg with
          None -> []
        | Some {ppat_desc = Ppat_tuple spl} when
            constr.cstr_arity > 1 ||
            Builtin_attributes.explicit_arity sp.ppat_attributes
          -> spl
        | Some({ppat_desc = Ppat_any} as sp) when constr.cstr_arity <> 1 ->
            if constr.cstr_arity = 0 then
              Location.prerr_warning sp.ppat_loc
                                     Warnings.Wildcard_arg_to_constant_constr;
            replicate_list sp constr.cstr_arity
        | Some sp -> [sp] in
      begin match sargs with
      | [{ppat_desc = Ppat_constant _} as sp]
        when Builtin_attributes.warn_on_literal_pattern
            constr.cstr_attributes ->
          Location.prerr_warning sp.ppat_loc
            Warnings.Fragile_literal_pattern
      | _ -> ()
      end;
      if List.length sargs <> constr.cstr_arity then
        raise(Error(loc, !env, Constructor_arity_mismatch(lid.txt,
                                     constr.cstr_arity, List.length sargs)));
      let (ty_args, ty_res) =
        instance_constructor ~in_pattern:(env, get_newtype_level ()) constr
      in
      (* PR#7214: do not use gadt unification for toplevel lets *)
      if not constr.cstr_generalized || mode = Inside_or || no_existentials
      then unify_pat_types loc !env ty_res expected_ty
      else unify_pat_types_gadt loc env ty_res expected_ty;

      let rec check_non_escaping p =
        match p.ppat_desc with
        | Ppat_or (p1, p2) ->
            check_non_escaping p1;
            check_non_escaping p2
        | Ppat_alias (p, _) ->
            check_non_escaping p
        | Ppat_constraint _ ->
            raise (Error (p.ppat_loc, !env, Inlined_record_escape))
        | _ ->
            ()
      in
      if constr.cstr_inlined <> None then List.iter check_non_escaping sargs;

      map_fold_cont (fun (p,t) -> type_pat p t) (List.combine sargs ty_args)
      (fun args ->
        rp k {
          pat_desc=Tpat_construct(lid, constr, args);
          pat_loc = loc; pat_extra=[];
          pat_type = expected_ty;
          pat_attributes = sp.ppat_attributes;
          pat_env = !env })
  | Ppat_variant(l, sarg) ->
      let arg_type = match sarg with None -> [] | Some _ -> [newvar()] in
      let row = { row_fields =
                    [l, Reither(sarg = None, arg_type, true, ref None)];
                  row_bound = ();
                  row_closed = false;
                  row_more = newvar ();
                  row_fixed = false;
                  row_name = None } in
      (* PR#7404: allow some_other_tag blindly, as it would not unify with
         the abstract row variable *)
      if l = Parmatch.some_other_tag then assert (constrs <> None)
      else unify_pat_types loc !env (newty (Tvariant row)) expected_ty;
      let k arg =
        rp k {
        pat_desc = Tpat_variant(l, arg, ref {row with row_more = newvar()});
        pat_loc = loc; pat_extra=[];
        pat_type =  expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env }
      in begin
        (* PR#6235: propagate type information *)
        match sarg, arg_type with
          Some p, [ty] -> type_pat p ty (fun p -> k (Some p))
        | _            -> k None
      end
  | Ppat_record(lid_sp_list, closed) ->
      assert (lid_sp_list <> []);
      let opath, record_ty =
        try
          let (p0, p, _, _) = extract_concrete_record !env expected_ty in
          Some (p0, p), expected_ty
        with Not_found -> None, newvar ()
      in
      let process_optional_label (ld, pat) =
        let exp_optional_attr = check_optional_attr !env ld pat.ppat_attributes pat.ppat_loc in
        let isFromPamatch = match pat.ppat_desc with
          | Ppat_construct ({txt = Lident s}, _) ->
            String.length s >= 2 && s.[0] = '#' && s.[1] = '$'
          | _ -> false
        in
        if label_is_optional ld && not exp_optional_attr && not isFromPamatch then
          let lid = mknoloc (Longident.(Ldot (Lident "*predef*", "Some"))) in
          Ast_helper.Pat.construct ~loc:pat.ppat_loc lid (Some pat)
        else pat
      in    
      let type_label_pat (label_lid, label, sarg) k =
        let sarg = process_optional_label (label, sarg) in
        begin_def ();
        let (vars, ty_arg, ty_res) = instance_label false label in
        if vars = [] then end_def ();
        begin try
          unify_pat_types loc !env ty_res record_ty
        with Unify trace ->
          raise(Error(label_lid.loc, !env,
                      Label_mismatch(label_lid.txt, trace)))
        end;
        type_pat sarg ty_arg (fun arg ->
          if vars <> [] then begin
            end_def ();
            generalize ty_arg;
            List.iter generalize vars;
            let instantiated tv =
              let tv = expand_head !env tv in
              not (is_Tvar tv) || tv.level <> generic_level in
            if List.exists instantiated vars then
              raise
                (Error(label_lid.loc, !env, Polymorphic_label label_lid.txt))
          end;
          k (label_lid, label, arg))
      in
      let k' k lbl_pat_list =
        check_recordpat_labels loc lbl_pat_list closed;
        unify_pat_types loc !env record_ty expected_ty;
        rp k {
        pat_desc = Tpat_record (lbl_pat_list, closed);
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env }
      in
      if constrs = None then
        k (wrap_disambiguate "This record pattern is expected to have"
             expected_ty
             (type_label_a_list ?labels loc false !env type_label_pat opath
                lid_sp_list)
             (k' (fun x -> x)))
      else
        type_label_a_list ?labels loc false !env type_label_pat opath
          lid_sp_list (k' k)
  | Ppat_array spl ->
      let ty_elt = newvar() in
      unify_pat_types
        loc !env (instance_def (Predef.type_array ty_elt)) expected_ty;
      let spl_ann = List.map (fun p -> (p,newvar())) spl in
      map_fold_cont (fun (p,_) -> type_pat p ty_elt) spl_ann (fun pl ->
        rp k {
        pat_desc = Tpat_array pl;
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env })
  | Ppat_or(sp1, sp2) ->
      let state = save_state env in
      begin match
        if mode = Split_or || mode = Splitting_or then raise Need_backtrack;
        let initial_pattern_variables = !pattern_variables in
        let initial_module_variables = !module_variables in
        let p1 =
          try Some (type_pat ~mode:Inside_or sp1 expected_ty (fun x -> x))
          with Need_backtrack -> None in
        let p1_variables = !pattern_variables in
        let p1_module_variables = !module_variables in
        pattern_variables := initial_pattern_variables;
        module_variables := initial_module_variables;
        let p2 =
          try Some (type_pat ~mode:Inside_or sp2 expected_ty (fun x -> x))
          with Need_backtrack -> None in
        let p2_variables = !pattern_variables in
        match p1, p2 with
          None, None -> raise Need_backtrack
        | Some p, None | None, Some p -> p (* no variables in this case *)
        | Some p1, Some p2 ->
        let alpha_env =
          enter_orpat_variables loc !env p1_variables p2_variables in
        pattern_variables := p1_variables;
        module_variables := p1_module_variables;
        { pat_desc = Tpat_or(p1, alpha_pat alpha_env p2, None);
          pat_loc = loc; pat_extra=[];
          pat_type = expected_ty;
          pat_attributes = sp.ppat_attributes;
          pat_env = !env }
      with
        p -> rp k p
      | exception Need_backtrack when mode <> Inside_or ->
          assert (constrs <> None);
          set_state state env;
          let mode =
            if mode = Split_or then mode else Splitting_or in
          try type_pat ~mode sp1 expected_ty k with Error _ ->
            set_state state env;
            type_pat ~mode sp2 expected_ty k
      end
  | Ppat_lazy sp1 ->
      let nv = newvar () in
      unify_pat_types loc !env (instance_def (Predef.type_lazy_t nv))
        expected_ty;
      (* do not explode under lazy: PR#7421 *)
      type_pat ~explode:0 sp1 nv (fun p1 ->
        rp k {
        pat_desc = Tpat_lazy p1;
        pat_loc = loc; pat_extra=[];
        pat_type = expected_ty;
        pat_attributes = sp.ppat_attributes;
        pat_env = !env })
  | Ppat_constraint(sp, sty) ->
      (* Separate when not already separated by !principal *)
      let separate = true in
      if separate then begin_def();
      let cty, force = Typetexp.transl_simple_type_delayed !env sty in
      let ty = cty.ctyp_type in
      let ty, expected_ty' =
        if separate then begin
          end_def();
          generalize_structure ty;
          instance !env ty, instance !env ty
        end else ty, ty
      in
      unify_pat_types loc !env ty expected_ty;
      type_pat sp expected_ty' (fun p ->
        (*Format.printf "%a@.%a@."
          Printtyp.raw_type_expr ty
          Printtyp.raw_type_expr p.pat_type;*)
        pattern_force := force :: !pattern_force;
        let extra = (Tpat_constraint cty, loc, sp.ppat_attributes) in
        let p =
          if not separate then p else
          match p.pat_desc with
            Tpat_var (id,s) ->
              {p with pat_type = ty;
               pat_desc = Tpat_alias
                 ({p with pat_desc = Tpat_any; pat_attributes = []}, id,s);
               pat_extra = [extra];
             }
          | _ -> {p with pat_type = ty;
                  pat_extra = extra :: p.pat_extra}
        in k p)
  | Ppat_type lid ->
      let (path, p,ty) = build_or_pat !env loc lid in
      unify_pat_types loc !env ty expected_ty;
      k { p with pat_extra =
        (Tpat_type (path, lid), loc, sp.ppat_attributes) :: p.pat_extra }
  | Ppat_open (lid,p) ->
      let path, new_env =
        !type_open Asttypes.Fresh !env sp.ppat_loc lid in
      let new_env = ref new_env in
      type_pat ~env:new_env p expected_ty ( fun p ->
        env := Env.copy_local !env ~from:!new_env;
        k { p with pat_extra =( Tpat_open (path,lid,!new_env),
                            loc, sp.ppat_attributes) :: p.pat_extra }
      )
  | Ppat_exception _ ->
      raise (Error (loc, !env, Exception_pattern_below_toplevel))
  | Ppat_extension ext ->
      raise (Error_forward (Builtin_attributes.error_of_extension ext))

let type_pat ?(allow_existentials=false) ?constrs ?labels ?(mode=Normal)
    ?(explode=0) ?(lev=get_current_level()) env sp expected_ty =
  newtype_level := Some lev;
  try
    let r =
      type_pat ~no_existentials:(not allow_existentials) ~constrs ~labels
        ~mode ~explode ~env sp expected_ty (fun x -> x) in
    iter_pattern (fun p -> p.pat_env <- !env) r;
    newtype_level := None;
    r
  with e ->
    newtype_level := None;
    raise e


(* this function is passed to Partial.parmatch
   to type check gadt nonexhaustiveness *)
let partial_pred ~lev ?mode ?explode env expected_ty constrs labels p =
  let env = ref env in
  let state = save_state env in
  try
    reset_pattern None true;
    let typed_p =
      Ctype.with_passive_variants
        (type_pat ~allow_existentials:true ~lev
           ~constrs ~labels ?mode ?explode env p)
        expected_ty
    in
    set_state state env;
    (* types are invalidated but we don't need them here *)
    Some typed_p
  with Error _ ->
    set_state state env;
    None

let check_partial ?(lev=get_current_level ()) env expected_ty loc cases =
  let explode = match cases with [_] -> 5 | _ -> 0 in
  Parmatch.check_partial_gadt
    (partial_pred ~lev ~explode env expected_ty) loc cases

let check_unused ?(lev=get_current_level ()) env expected_ty cases =
  Parmatch.check_unused
    (fun refute constrs labels spat ->
      match
        partial_pred ~lev ~mode:Split_or ~explode:5
          env expected_ty constrs labels spat
      with
        Some pat when refute ->
          raise (Error (spat.ppat_loc, env, Unrefuted_pattern pat))
      | r -> r)
    cases

let add_pattern_variables ?check ?check_as env =
  let pv = get_ref pattern_variables in
  (List.fold_right
     (fun (id, ty, _name, loc, as_var) env ->
       let check = if as_var then check_as else check in
       Env.add_value ?check id
         {val_type = ty; val_kind = Val_reg; Types.val_loc = loc;
          val_attributes = [];
         } env
     )
     pv env,
   get_ref module_variables)

let type_pattern ~lev env spat scope expected_ty =
  reset_pattern scope true;
  let new_env = ref env in
  let pat = type_pat ~allow_existentials:true ~lev new_env spat expected_ty in
  let new_env, unpacks =
    add_pattern_variables !new_env
      ~check:(fun s -> Warnings.Unused_var_strict s)
      ~check_as:(fun s -> Warnings.Unused_var s) in
  (pat, new_env, get_ref pattern_force, unpacks)

let type_pattern_list env spatl scope expected_tys allow =
  reset_pattern scope allow;
  let new_env = ref env in
  let type_pat (attrs, pat) ty =
    Builtin_attributes.warning_scope ~ppwarning:false attrs
      (fun () ->
         type_pat new_env pat ty
      )
  in
  let patl = List.map2 type_pat spatl expected_tys in
  let new_env, unpacks = add_pattern_variables !new_env in
  (patl, new_env, get_ref pattern_force, unpacks)




let rec final_subexpression sexp =
  match sexp.pexp_desc with
    Pexp_let (_, _, e)
  | Pexp_sequence (_, e)
  | Pexp_try (e, _)
  | Pexp_ifthenelse (_, e, _)
  | Pexp_match (_, {pc_rhs=e} :: _)
    -> final_subexpression e
  | _ -> sexp

(* Generalization criterion for expressions *)

let rec is_nonexpansive exp =
  List.exists (function (({txt = "internal.expansive"},_) : Parsetree.attribute) -> true | _ -> false)
   exp.exp_attributes ||
  match exp.exp_desc with
    Texp_ident(_,_,_) -> true
  | Texp_constant _ -> true
  | Texp_let(_rec_flag, pat_exp_list, body) ->
      List.for_all (fun vb -> is_nonexpansive vb.vb_expr) pat_exp_list &&
      is_nonexpansive body
  | Texp_function _ -> true
  | Texp_apply(e, (_,None)::el) ->
      is_nonexpansive e && List.for_all is_nonexpansive_opt (List.map snd el)
  | Texp_match(e, cases, [], _) ->
      is_nonexpansive e &&
      List.for_all
        (fun {c_lhs = _; c_guard; c_rhs} ->
           is_nonexpansive_opt c_guard && is_nonexpansive c_rhs
        ) cases
  | Texp_tuple el ->
      List.for_all is_nonexpansive el
  | Texp_construct( _, _, el) ->
      List.for_all is_nonexpansive el
  | Texp_variant(_, arg) -> is_nonexpansive_opt arg
  | Texp_record { fields; extended_expression } ->
      Array.for_all
        (fun (lbl, definition) ->
           match definition with
           | Overridden (_, exp) ->
               lbl.lbl_mut = Immutable && is_nonexpansive exp
           | Kept _ -> true)
        fields
      && is_nonexpansive_opt extended_expression
  | Texp_field(exp, _, _) -> is_nonexpansive exp
  | Texp_array [] ->  !Config.unsafe_empty_array
  | Texp_ifthenelse(_cond, ifso, ifnot) ->
      is_nonexpansive ifso && is_nonexpansive_opt ifnot
  | Texp_sequence (_e1, e2) -> is_nonexpansive e2  (* PR#4354 *)
  | Texp_new _ ->
      assert false
  (* Note: nonexpansive only means no _observable_ side effects *)
  | Texp_lazy e -> is_nonexpansive e
  | Texp_object () ->
    assert false
  | Texp_letmodule (_, _, mexp, e) ->
      is_nonexpansive_mod mexp && is_nonexpansive e
  | Texp_pack mexp ->
      is_nonexpansive_mod mexp
  (* Computations which raise exceptions are nonexpansive, since (raise e) is equivalent
     to (raise e; diverge), and a nonexpansive "diverge" can be produced using lazy values
     or the relaxed value restriction. See GPR#1142 *)
  | Texp_assert exp ->
      is_nonexpansive exp
  | Texp_apply (
      { exp_desc = Texp_ident (_, _, {val_kind =
             Val_prim {Primitive.prim_name = "%raise"}}) },
      [Nolabel, Some e]) ->
     is_nonexpansive e
  | _ -> false

and is_nonexpansive_mod mexp =
  match mexp.mod_desc with
  | Tmod_ident _ -> true
  | Tmod_functor _ -> true
  | Tmod_unpack (e, _) -> is_nonexpansive e
  | Tmod_constraint (m, _, _, _) -> is_nonexpansive_mod m
  | Tmod_structure str ->
      List.for_all
        (fun item -> match item.str_desc with
          | Tstr_eval _ | Tstr_primitive _ | Tstr_type _
          | Tstr_modtype _ | Tstr_open _ | Tstr_class_type _  -> true
          | Tstr_value (_, pat_exp_list) ->
              List.for_all (fun vb -> is_nonexpansive vb.vb_expr) pat_exp_list
          | Tstr_module {mb_expr=m;_}
          | Tstr_include {incl_mod=m;_} -> is_nonexpansive_mod m
          | Tstr_recmodule id_mod_list ->
              List.for_all (fun {mb_expr=m;_} -> is_nonexpansive_mod m)
                id_mod_list
          | Tstr_exception {ext_kind = Text_decl _} ->
              false (* true would be unsound *)
          | Tstr_exception {ext_kind = Text_rebind _} -> true
          | Tstr_typext te ->
              List.for_all
                (function {ext_kind = Text_decl _} -> false
                        | {ext_kind = Text_rebind _} -> true)
                te.tyext_constructors
          | Tstr_class _ -> false (* could be more precise *)
          | Tstr_attribute _ -> true
        )
        str.str_items
  | Tmod_apply _ -> false

and is_nonexpansive_opt = function
    None -> true
  | Some e -> is_nonexpansive e




(* Approximate the type of an expression, for better recursion *)

let rec approx_type env sty =
  match sty.ptyp_desc with
    Ptyp_arrow (p, _, sty) ->
      let ty1 = if is_optional p then type_option (newvar ()) else newvar () in
      newty (Tarrow (p, ty1, approx_type env sty, Cok))
  | Ptyp_tuple args ->
      newty (Ttuple (List.map (approx_type env) args))
  | Ptyp_constr (lid, ctl) ->
      begin try
        let path = Env.lookup_type lid.txt env in
        let decl = Env.find_type path env in
        if List.length ctl <> decl.type_arity then raise Not_found;
        let tyl = List.map (approx_type env) ctl in
        newconstr path tyl
      with Not_found -> newvar ()
      end
  | Ptyp_poly (_, sty) ->
      approx_type env sty
  | _ -> newvar ()

let rec type_approx env sexp =
  match sexp.pexp_desc with
    Pexp_let (_, _, e) -> type_approx env e
  | Pexp_fun (p, _, _, e) ->
      let ty = if is_optional p then type_option (newvar ()) else newvar () in
      newty (Tarrow(p, ty, type_approx env e, Cok))
  | Pexp_function ({pc_rhs=e}::_) ->
      newty (Tarrow(Nolabel, newvar (), type_approx env e, Cok))
  | Pexp_match (_, {pc_rhs=e}::_) -> type_approx env e
  | Pexp_try (e, _) -> type_approx env e
  | Pexp_tuple l -> newty (Ttuple(List.map (type_approx env) l))
  | Pexp_ifthenelse (_,e,_) -> type_approx env e
  | Pexp_sequence (_,e) -> type_approx env e
  | Pexp_constraint (e, sty) ->
      let ty = type_approx env e in
      let ty1 = approx_type env sty in
      begin try unify env ty ty1 with Unify trace ->
        raise(Error(sexp.pexp_loc, env, Expr_type_clash trace))
      end;
      ty1
  | Pexp_coerce (e, sty1, sty2) ->
      let approx_ty_opt = function
        | None -> newvar ()
        | Some sty -> approx_type env sty
      in
      let ty = type_approx env e
      and ty1 = approx_ty_opt sty1
      and ty2 = approx_type env sty2 in
      begin try unify env ty ty1 with Unify trace ->
        raise(Error(sexp.pexp_loc, env, Expr_type_clash trace))
      end;
      ty2
  | _ -> newvar ()

(* List labels in a function type, and whether return type is a variable *)
let rec list_labels_aux env visited ls ty_fun =
  let ty = expand_head env ty_fun in
  if List.memq ty visited then
    List.rev ls, false
  else match ty.desc with
    Tarrow (l, _, ty_res, _) ->
      list_labels_aux env (ty::visited) (l::ls) ty_res
  | _ ->
      List.rev ls, is_Tvar ty

let list_labels env ty =
  wrap_trace_gadt_instances env (list_labels_aux env [] []) ty

(* Check that all univars are safe in a type *)
let check_univars env expans kind exp ty_expected vars =
  if expans && not (is_nonexpansive exp) then
    generalize_expansive env exp.exp_type;
  (* need to expand twice? cf. Ctype.unify2 *)
  let vars = List.map (expand_head env) vars in
  let vars = List.map (expand_head env) vars in
  let vars' =
    Ext_list.filter vars
      (fun t ->
        let t = repr t in
        generalize t;
        match t.desc with
          Tvar name when t.level = generic_level ->
            log_type t; t.desc <- Tunivar name; true
        | _ -> false)
  in
  if List.length vars = List.length vars' then () else
  let ty = newgenty (Tpoly(repr exp.exp_type, vars'))
  and ty_expected = repr ty_expected in
  raise (Error (exp.exp_loc, env,
                Less_general(kind, [ty, ty; ty_expected, ty_expected])))

(* Check that a type is not a function *)
let check_application_result env statement exp =
  let loc = exp.exp_loc in
  match (expand_head env exp.exp_type).desc with
  | Tarrow _ ->
      Location.prerr_warning exp.exp_loc Warnings.Partial_application
  | Tvar _ -> ()
  | Tconstr (p, _, _) when Path.same p Predef.path_unit -> ()
  | _ ->
      if statement then
        Location.prerr_warning loc Warnings.Statement_type

(* Check that a type is generalizable at some level *)
let generalizable level ty =
  let rec check ty =
    let ty = repr ty in
    if ty.level < lowest_level then () else
    if ty.level <= level then raise Exit else
    (mark_type_node ty; iter_type_expr check ty)
  in
  try check ty; unmark_type ty; true
  with Exit -> unmark_type ty; false

(* Hack to allow coercion of self. Will clean-up later. *)
let self_coercion = ref ([] : (Path.t * Location.t list ref) list)

(* Helpers for packaged modules. *)
let create_package_type loc env (p, l) =
  let s = !Typetexp.transl_modtype_longident loc env p in
  let fields = List.map (fun (name, ct) ->
                           name, Typetexp.transl_simple_type env false ct) l in
  let ty = newty (Tpackage (s,
                    List.map fst l,
                   List.map (fun (_, cty) -> cty.ctyp_type) fields))
  in
   (s, fields, ty)

 let wrap_unpacks sexp unpacks =
   let open Ast_helper in
   List.fold_left
     (fun sexp (name, loc) ->
       Exp.letmodule ~loc:sexp.pexp_loc ~attrs:[mknoloc "#modulepat",PStr []]
         name
         (Mod.unpack ~loc
            (Exp.ident ~loc:name.loc (mkloc (Longident.Lident name.txt)
                                            name.loc)))
         sexp
     )
    sexp unpacks

(* Helpers for type_cases *)

let contains_variant_either ty =
  let rec loop ty =
    let ty = repr ty in
    if ty.level >= lowest_level then begin
      mark_type_node ty;
      match ty.desc with
        Tvariant row ->
          let row = row_repr row in
          if not row.row_fixed then
            List.iter
              (fun (_,f) ->
                match row_field_repr f with Reither _ -> raise Exit | _ -> ())
              row.row_fields;
          iter_row loop row
      | _ ->
          iter_type_expr loop ty
    end
  in
  try loop ty; unmark_type ty; false
  with Exit -> unmark_type ty; true

let iter_ppat f p =
  match p.ppat_desc with
  | Ppat_any | Ppat_var _ | Ppat_constant _ | Ppat_interval _
  | Ppat_extension _
  | Ppat_type _ | Ppat_unpack _ -> ()
  | Ppat_array pats -> List.iter f pats
  | Ppat_or (p1,p2) -> f p1; f p2
  | Ppat_variant (_, arg) | Ppat_construct (_, arg) -> may f arg
  | Ppat_tuple lst ->  List.iter f lst
  | Ppat_exception p | Ppat_alias (p,_)
  | Ppat_open (_,p)
  | Ppat_constraint (p,_) | Ppat_lazy p -> f p
  | Ppat_record (args, _flag) -> List.iter (fun (_,p) -> f p) args

let contains_polymorphic_variant p =
  let rec loop p =
    match p.ppat_desc with
      Ppat_variant _ | Ppat_type _ -> raise Exit
    | _ -> iter_ppat loop p
  in
  try loop p; false with Exit -> true

let contains_gadt env p =
  let rec loop env p =
    match p.ppat_desc with
      | Ppat_construct (lid, _) ->
        begin try
          let cstrs = Env.lookup_all_constructors lid.txt env in
          List.iter (fun (cstr,_) -> if cstr.cstr_generalized then raise_notrace Exit)
            cstrs
        with Not_found -> ()
        end; iter_ppat (loop env) p
      | Ppat_open (lid,sub_p) ->
        let _, new_env = !type_open Asttypes.Override env p.ppat_loc lid in
        loop new_env sub_p
    | _ -> iter_ppat (loop env) p
  in
  try loop env p; false with Exit -> true

let check_absent_variant env =
  iter_pattern
    (function {pat_desc = Tpat_variant (s, arg, row)} as pat ->
      let row = row_repr !row in
      if List.exists (fun (s',fi) -> s = s' && row_field_repr fi <> Rabsent)
          row.row_fields
      || not row.row_fixed && not (static_row row)  (* same as Ctype.poly *)
      then () else
      let ty_arg =
        match arg with None -> [] | Some p -> [correct_levels p.pat_type] in
      let row' = {row_fields = [s, Reither(arg=None,ty_arg,true,ref None)];
                  row_more = newvar (); row_bound = ();
                  row_closed = false; row_fixed = false; row_name = None} in
      (* Should fail *)
      unify_pat env {pat with pat_type = newty (Tvariant row')}
                    (correct_levels pat.pat_type)
      | _ -> ())

(* Duplicate types of values in the environment *)
(* XXX Should we do something about global type variables too? *)

let duplicate_ident_types caselist env =
  let caselist =
    Ext_list.filter caselist (fun {pc_lhs} -> contains_gadt env pc_lhs) in
  Env.copy_types (all_idents_cases caselist) env

  
(* type_label_a_list returns a list of labels sorted by lbl_pos *)
(* note: check_duplicates would better be implemented in
         type_label_a_list directly *)  
let rec check_duplicates loc env = function
  | (_, lbl1, _) :: (_, lbl2, _) :: _ when lbl1.lbl_pos = lbl2.lbl_pos ->
    raise(Error(loc, env, Label_multiply_defined lbl1.lbl_name))
  | _ :: rem ->
      check_duplicates loc env rem
  | [] -> ()  
(* Getting proper location of already typed expressions.

   Used to avoid confusing locations on type error messages in presence of
   type constraints.
   For example:

       (* Before patch *)
       # let x : string = (5 : int);;
                           ^
       (* After patch *)
       # let x : string = (5 : int);;
                          ^^^^^^^^^
*)
let proper_exp_loc exp =
  let rec aux = function
    | [] -> exp.exp_loc
    | ((Texp_constraint _ | Texp_coerce _), loc, _) :: _ -> loc
    | _ :: rest -> aux rest
  in
  aux exp.exp_extra

let id_of_pattern : Typedtree.pattern -> Ident.t option = fun pat -> 
  match pat.pat_desc with 
  | Tpat_var (id, _) -> Some id
  | Tpat_alias(_, id, _) -> Some id
  | Tpat_construct (_,_,
                    [{pat_desc = (Tpat_var (id,_) | Tpat_alias(_,id,_))}]) 
    -> Some (Ident.rename id)     
  | _ -> None
(* To find reasonable names for let-bound and lambda-bound idents *)

let rec name_pattern default = function
    [] -> Ident.create default
  | {c_lhs=p; _} :: rem ->
    match id_of_pattern p with 
    | None -> name_pattern default rem
    | Some id -> id    

(* Typing of expressions *)

let unify_exp env exp expected_ty =
  let loc = proper_exp_loc exp in
  unify_exp_types loc env exp.exp_type expected_ty


let is_ignore funct env =
  match funct.exp_desc with
    Texp_ident (_, _, {val_kind=Val_prim{Primitive.prim_name="%ignore"}}) ->
      (try ignore (filter_arrow env (instance env funct.exp_type) Nolabel);
             true
        with Unify _ -> false)
  | _ -> false

let not_identity = function
  | Texp_ident(_,_,{val_kind=Val_prim
                  {Primitive.prim_name="%identity"}}) ->
    false
  | _ -> true  

let rec lower_args env seen ty_fun  =
  let ty = expand_head env ty_fun in
    if List.memq ty seen then () else
    match ty.desc with
      Tarrow (_l, ty_arg, ty_fun, _com) ->
        (try unify_var env (newvar()) ty_arg with Unify _ -> assert false);
        lower_args env (ty::seen) ty_fun
    | _ -> ()

let not_function env ty =
  let ls, tvar = list_labels env ty in
  ls = [] && not tvar
    
type lazy_args = 
  (Asttypes.arg_label * (unit -> Typedtree.expression) option) list

type targs = 
  (Asttypes.arg_label * Typedtree.expression option) list  
let rec type_exp ?recarg env sexp =
  (* We now delegate everything to type_expect *)
  type_expect ?recarg env sexp (newvar ())

(* Typing of an expression with an expected type.
   This provide better error messages, and allows controlled
   propagation of return type information.
   In the principal case, [type_expected'] may be at generic_level.
 *)

and type_expect ?in_function ?recarg env sexp ty_expected =
  let previous_saved_types = Cmt_format.get_saved_types () in
  let exp =
    Builtin_attributes.warning_scope sexp.pexp_attributes
      (fun () ->
         type_expect_ ?in_function ?recarg env sexp ty_expected
      )
  in
  Cmt_format.set_saved_types
  (Cmt_format.Partial_expression exp :: previous_saved_types);
  exp

and type_expect_ ?in_function ?(recarg=Rejected) env sexp ty_expected =
  let loc = sexp.pexp_loc in
  (* Record the expression type before unifying it with the expected type *)
  let rue exp =
    unify_exp env (re exp) (instance env ty_expected);
    exp
  in
  let process_optional_label (id, ld, e) =
    let exp_optional_attr = check_optional_attr env ld e.pexp_attributes e.pexp_loc in
    if label_is_optional ld && not exp_optional_attr then
      let lid = mknoloc (Longident.(Ldot (Lident "*predef*", "Some"))) in
      let e = Ast_helper.Exp.construct ~loc:e.pexp_loc lid (Some e)
      in (id, ld, e)
    else (id, ld, e)
  in
  match sexp.pexp_desc with
  | Pexp_ident lid ->
      begin
        let (path, desc) = Typetexp.find_value env lid.loc lid.txt in
        if !Clflags.annotations then begin
          let dloc = desc.Types.val_loc in
          let annot =
            if dloc.Location.loc_ghost then Annot.Iref_external
            else Annot.Iref_internal dloc
          in
          let name = Path.name ~paren:Oprint.parenthesized_ident path in
          Stypes.record (Stypes.An_ident (loc, name, annot))
        end;
        let is_recarg =
          match (repr desc.val_type).desc with
          | Tconstr(p, _, _) -> Path.is_constructor_typath p
          | _ -> false
        in

        begin match is_recarg, recarg, (repr desc.val_type).desc with
        | _, Allowed, _
        | true, Required, _
        | false, Rejected, _
          -> ()
        | true, Rejected, _
        | false, Required, (Tvar _ | Tconstr _) ->
            raise (Error (loc, env, Inlined_record_escape))
        | false, Required, _  ->
            () (* will fail later *)
        end;
        rue {
          exp_desc = Texp_ident(path, lid, desc);
          exp_loc = loc; exp_extra = [];
          exp_type = instance env desc.val_type;
          exp_attributes = sexp.pexp_attributes;
          exp_env = env }
      end
  | Pexp_constant cst ->
      let cst = constant_or_raise env loc cst in
      rue {
        exp_desc = Texp_constant cst;
        exp_loc = loc; exp_extra = [];
        exp_type = type_constant cst;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_let(Nonrecursive,
             [{pvb_pat=spat; pvb_expr=sval; pvb_attributes=[]}], sbody)
    when contains_gadt env spat ->
    (* TODO: allow non-empty attributes? *)
      type_expect ?in_function env
        {sexp with
         pexp_desc = Pexp_match (sval, [Ast_helper.Exp.case spat sbody])}
        ty_expected
  | Pexp_let(rec_flag, spat_sexp_list, sbody) ->
      let scp =
        match sexp.pexp_attributes, rec_flag with
        | [{txt="#default"},_], _ -> None
        | _, Recursive -> Some (Annot.Idef loc)
        | _, Nonrecursive -> Some (Annot.Idef sbody.pexp_loc)
      in
      let (pat_exp_list, new_env, unpacks) =
        type_let env rec_flag spat_sexp_list scp true in
      let body =
        type_expect new_env (wrap_unpacks sbody unpacks) ty_expected in
      let () =
        if rec_flag = Recursive then
          Rec_check.check_recursive_bindings pat_exp_list
      in
      re {
        exp_desc = Texp_let(rec_flag, pat_exp_list, body);
        exp_loc = loc; exp_extra = [];
        exp_type = body.exp_type;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_fun (l, Some default, spat, sbody) ->
      assert(is_optional l); (* default allowed only with optional argument *)
      let open Ast_helper in
      let default_loc = default.pexp_loc in
      let scases = [
        Exp.case
          (Pat.construct ~loc:default_loc
             (mknoloc (Longident.(Ldot (Lident "*predef*", "Some"))))
             (Some (Pat.var ~loc:default_loc (mknoloc "*sth*"))))
          (Exp.ident ~loc:default_loc (mknoloc (Longident.Lident "*sth*")));

        Exp.case
          (Pat.construct ~loc:default_loc
             (mknoloc (Longident.(Ldot (Lident "*predef*", "None"))))
             None)
          default;
       ]
      in
      let sloc =
        { Location.loc_start = spat.ppat_loc.Location.loc_start;
          loc_end = default_loc.Location.loc_end;
          loc_ghost = true }
      in
      let smatch =
        Exp.match_ ~loc:sloc
          (Exp.ident ~loc (mknoloc (Longident.Lident "*opt*")))
          scases
      in
      let pat = Pat.var ~loc:sloc (mknoloc "*opt*") in
      let body =
        Exp.let_ ~loc Nonrecursive ~attrs:[mknoloc "#default",PStr []]
          [Vb.mk spat smatch] sbody
      in
      type_function ?in_function loc sexp.pexp_attributes env ty_expected
        l [Exp.case pat body]
  | Pexp_fun (l, None, spat, sbody) ->
      type_function ?in_function loc sexp.pexp_attributes env ty_expected
        l [Ast_helper.Exp.case spat sbody]
  | Pexp_function caselist ->
      type_function ?in_function
        loc sexp.pexp_attributes env ty_expected Nolabel caselist
  | Pexp_apply(sfunct, sargs) ->
      assert (sargs <> []);
      begin_def (); (* one more level for non-returning functions *)
      let funct = type_exp env sfunct in
      let ty = instance env funct.exp_type in
      end_def ();
      wrap_trace_gadt_instances env (lower_args env []) ty;
      begin_def ();
      let uncurried = Ext_list.exists sexp.pexp_attributes (fun ({txt },_) -> txt = "res.uapp") in
      let (args, ty_res, fully_applied) = type_application uncurried env funct sargs in
      end_def ();
      unify_var env (newvar()) funct.exp_type;

      let mk_exp ?(loc=Location.none) exp_desc exp_type =
        { exp_desc;
          exp_loc = loc; exp_extra = [];
          exp_type;
          exp_attributes = [];
          exp_env = env } in
      let apply_internal name e =
        let lid:Longident.t = Ldot (Ldot (Lident "Js", "Internal"), name) in
        let (path, desc) = Env.lookup_value lid env in
        let id = mk_exp (Texp_ident(path, {txt=lid; loc=Location.none}, desc)) desc.val_type in
        mk_exp ~loc:e.exp_loc (Texp_apply(id, [(Nolabel, Some e)])) e.exp_type in
        
      let mk_apply funct args =
        rue {
          exp_desc = Texp_apply(funct, args);
          exp_loc = loc; exp_extra = [];
          exp_type = ty_res;
          exp_attributes = sexp.pexp_attributes;
          exp_env = env } in

      let is_primitive = match funct.exp_desc with
        | Texp_ident (_, _, {val_kind = Val_prim _}) -> true
        | _ -> false in

      if fully_applied && not is_primitive then
        rue (apply_internal "opaqueFullApply" (mk_apply (apply_internal "opaque" funct) args))
      else
        rue (mk_apply funct args)
  | Pexp_match(sarg, caselist) ->
      begin_def ();
      let arg = type_exp env sarg in
      end_def ();
      if not (is_nonexpansive arg) then generalize_expansive env arg.exp_type;
      generalize arg.exp_type;
      let rec split_cases vc ec = function
        | [] -> List.rev vc, List.rev ec
        | {pc_lhs = {ppat_desc=Ppat_exception p}} as c :: rest ->
            split_cases vc ({c with pc_lhs = p} :: ec) rest
        | c :: rest ->
            split_cases (c :: vc) ec rest
      in
      let val_caselist, exn_caselist = split_cases [] [] caselist in
      if val_caselist = [] && exn_caselist <> [] then
        raise (Error (loc, env, No_value_clauses));
      (* Note: val_caselist = [] and exn_caselist = [], i.e. a fully
         empty pattern matching can be generated by Camlp4 with its
         revised syntax.  Let's accept it for backward compatibility. *)
      let val_cases, partial =
        type_cases env arg.exp_type ty_expected true loc val_caselist in
      let exn_cases, _ =
        type_cases env Predef.type_exn ty_expected false loc exn_caselist in
      re {
        exp_desc = Texp_match(arg, val_cases, exn_cases, partial);
        exp_loc = loc; exp_extra = [];
        exp_type = instance env ty_expected;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_try(sbody, caselist) ->
      let body = type_expect env sbody ty_expected in
      let cases, _ =
        type_cases env Predef.type_exn ty_expected false loc caselist in
      re {
        exp_desc = Texp_try(body, cases);
        exp_loc = loc; exp_extra = [];
        exp_type = body.exp_type;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_tuple sexpl ->
      assert (List.length sexpl >= 2);
      let subtypes = List.map (fun _ -> newgenvar ()) sexpl in
      let to_unify = newgenty (Ttuple subtypes) in
      unify_exp_types loc env to_unify ty_expected;
      let expl =
        List.map2 (fun body ty -> type_expect env body ty) sexpl subtypes
      in
      re {
        exp_desc = Texp_tuple expl;
        exp_loc = loc; exp_extra = [];
        (* Keep sharing *)
        exp_type = newty (Ttuple (List.map (fun e -> e.exp_type) expl));
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_construct(lid, sarg) ->
      (match lid.txt with
      | Lident "Function$" ->
        let arity = Ast_uncurried.attributes_to_arity sexp.pexp_attributes in
        let uncurried_typ = Ast_uncurried.make_uncurried_type ~env ~arity (newvar()) in
        unify_exp_types loc env ty_expected uncurried_typ
      | _ -> ());
      type_construct env loc lid sarg ty_expected sexp.pexp_attributes
  | Pexp_variant(l, sarg) ->
      (* Keep sharing *)
      let ty_expected0 = instance env ty_expected in
      begin try match
        sarg, expand_head env ty_expected, expand_head env ty_expected0 with
      | Some sarg, {desc = Tvariant row}, {desc = Tvariant row0} ->
          let row = row_repr row in
          begin match row_field_repr (List.assoc l row.row_fields),
          row_field_repr (List.assoc l row0.row_fields) with
            Rpresent (Some ty), Rpresent (Some ty0) ->
              let arg = type_argument env sarg ty ty0 in
              re { exp_desc = Texp_variant(l, Some arg);
                   exp_loc = loc; exp_extra = [];
                   exp_type = ty_expected0;
                   exp_attributes = sexp.pexp_attributes;
                   exp_env = env }
          | _ -> raise Not_found
          end
      | _ -> raise Not_found
      with Not_found ->
        let arg = may_map (type_exp env) sarg in
        let arg_type = may_map (fun arg -> arg.exp_type) arg in
        rue {
          exp_desc = Texp_variant(l, arg);
          exp_loc = loc; exp_extra = [];
          exp_type= newty (Tvariant{row_fields = [l, Rpresent arg_type];
                                    row_more = newvar ();
                                    row_bound = ();
                                    row_closed = false;
                                    row_fixed = false;
                                    row_name = None});
          exp_attributes = sexp.pexp_attributes;
          exp_env = env }
      end
    | Pexp_record(lid_sexp_list, None) ->
        let ty_record, opath, fields, repr_opt =          
          match extract_concrete_record env ty_expected with
          |  (p0, p, fields, repr) ->
              (* XXX level may be wrong *)
              ty_expected, Some (p0, p), fields, Some repr 
          | exception Not_found -> 
               newvar (), None, [], None
          
        in
        let lbl_exp_list =
          wrap_disambiguate "This record expression is expected to have" ty_record
            (type_label_a_list loc true env
               (fun e k -> k (type_label_exp true env loc ty_record (process_optional_label e)))
               opath lid_sexp_list)
            (fun x -> x)
        in
        unify_exp_types loc env ty_record (instance env ty_expected);
        check_duplicates loc env lbl_exp_list;
        let label_descriptions, representation = match lbl_exp_list, repr_opt with
        | (_, { lbl_all = label_descriptions; lbl_repres = representation}, _) :: _, _ -> label_descriptions, representation
        | [], Some (representation) when lid_sexp_list = [] ->
            let optional_labels = match representation with
            | Record_optional_labels optional_labels -> optional_labels
            | Record_inlined {optional_labels} -> optional_labels
            | _ -> [] in
            let filter_missing (ld : Types.label_declaration) =
              let name = Ident.name ld.ld_id in
              if List.mem name optional_labels then
                None
              else
                Some name in
            let labels_missing = fields |> List.filter_map filter_missing in
            if labels_missing <> [] then
              raise(Error(loc, env, Labels_missing labels_missing));
            [||], representation
        | [], _ ->
          if fields = [] && repr_opt <> None then
            [||], Record_optional_labels []
          else
            raise(Error(loc, env, Empty_record_literal)) in
        let labels_missing = ref [] in
        let label_definitions =
          let matching_label lbl =
            List.find
              (fun (_, lbl',_) -> lbl'.lbl_pos = lbl.lbl_pos)
              lbl_exp_list
          in
          Array.map 
          (fun lbl ->
                    match matching_label lbl with
                    | (lid, _lbl, lbl_exp) ->
                        Overridden (lid, lbl_exp)
                    | exception Not_found ->
                      if not (label_is_optional lbl) then labels_missing := lbl.lbl_name :: !labels_missing;
                      Overridden ({loc ; txt = Lident lbl.lbl_name}, option_none lbl.lbl_arg loc))
                  label_descriptions
        in
        if !labels_missing <> [] then
          raise(Error(loc, env, Labels_missing (List.rev !labels_missing)));
        let fields =
          Array.map2 (fun descr def -> descr, def)
            label_descriptions label_definitions
        in
        re {
          exp_desc = Texp_record {
              fields; representation;
              extended_expression = None
            };
          exp_loc = loc; exp_extra = [];
          exp_type = instance env ty_expected;
          exp_attributes = sexp.pexp_attributes;
          exp_env = env }      
  | Pexp_record(lid_sexp_list, Some sexp) ->
      assert (lid_sexp_list <> []);      
      let exp = type_exp ~recarg env sexp in                  
      let ty_record, opath =
        let get_path ty =
          try
            let (p0, p, _, _) = extract_concrete_record env ty in
            (* XXX level may be wrong *)
            Some (p0, p) 
          with Not_found -> None
        in
        match get_path ty_expected with
          None ->
            begin 
                match get_path exp.exp_type with
                  None -> newvar (), None
                | Some (_, p') as op ->
                    let decl = Env.find_type p' env in
                    begin_def ();
                    let ty =
                      newconstr p' (instance_list env decl.type_params) in
                    end_def ();
                    generalize_structure ty;
                    ty, op
            end
        | op -> ty_expected, op
      in
      let closed = false in
      let lbl_exp_list =
        wrap_disambiguate "This record expression is expected to have" ty_record
          (type_label_a_list loc closed env
             (fun e k -> k (type_label_exp true env loc ty_record (process_optional_label e)))
             opath lid_sexp_list)
          (fun x -> x)
      in
      unify_exp_types loc env ty_record (instance env ty_expected);
      check_duplicates loc env lbl_exp_list;
      let opt_exp, label_definitions =
        let (_lid, lbl, _lbl_exp) = List.hd lbl_exp_list in
        let matching_label lbl =
          List.find
            (fun (_, lbl',_) -> lbl'.lbl_pos = lbl.lbl_pos)
            lbl_exp_list
        in
            let ty_exp = instance env exp.exp_type in
            let unify_kept lbl =
              let _, ty_arg1, ty_res1 = instance_label false lbl in
              unify_exp_types exp.exp_loc env ty_exp ty_res1;
              match matching_label lbl with
              | lid, _lbl, lbl_exp ->
                  (* do not connect result types for overridden labels *)
                  Overridden (lid, lbl_exp)
              | exception Not_found -> begin
                  let _, ty_arg2, ty_res2 = instance_label false lbl in
                  unify_exp_types loc env ty_arg1 ty_arg2;
                  unify_exp_types loc env (instance env ty_expected) ty_res2;
                  Kept ty_arg1
                end
            in
            let label_definitions = Array.map unify_kept lbl.lbl_all in
            Some {exp with exp_type = ty_exp}, label_definitions
      in
      let num_fields =
        match lbl_exp_list with [] -> assert false
        | (_, lbl,_)::_ -> Array.length lbl.lbl_all in
      let opt_exp =
        if List.length lid_sexp_list = num_fields then
          (Location.prerr_warning loc Warnings.Useless_record_with; None)
        else opt_exp
      in
      let label_descriptions, representation =
        let (_, { lbl_all; lbl_repres }, _) = List.hd lbl_exp_list in
        lbl_all, lbl_repres
      in
      let fields =
        Array.map2 (fun descr def -> descr, def)
          label_descriptions label_definitions
      in
      re {
        exp_desc = Texp_record {
            fields; representation;
            extended_expression = opt_exp
          };
        exp_loc = loc; exp_extra = [];
        exp_type = instance env ty_expected;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_field(srecord, lid) ->
      let (record, label, _) = type_label_access env srecord lid in
      let (_, ty_arg, ty_res) = instance_label false label in
      unify_exp env record ty_res;
      rue {
        exp_desc = Texp_field(record, lid, label);
        exp_loc = loc; exp_extra = [];
        exp_type = ty_arg;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_setfield(srecord, lid, snewval) ->
      let (record, label, opath) = type_label_access env srecord lid in
      let ty_record = if opath = None then newvar () else record.exp_type in
      let (label_loc, label, newval) =
        type_label_exp false env loc ty_record (lid, label, snewval) in
      unify_exp env record ty_record;
      if label.lbl_mut = Immutable then
        raise(Error(loc, env, Label_not_mutable lid.txt));
      Builtin_attributes.check_deprecated_mutable lid.loc label.lbl_attributes
        (Longident.last lid.txt);
      rue {
        exp_desc = Texp_setfield(record, label_loc, label, newval);
        exp_loc = loc; exp_extra = [];
        exp_type = instance_def Predef.type_unit;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_array(sargl) ->
      let ty = newgenvar() in
      let to_unify = Predef.type_array ty in
      unify_exp_types loc env to_unify ty_expected;
      let argl = List.map (fun sarg -> type_expect env sarg ty) sargl in
      re {
        exp_desc = Texp_array argl;
        exp_loc = loc; exp_extra = [];
        exp_type = instance env ty_expected;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_ifthenelse(scond, sifso, sifnot) ->
      let cond = type_expect env scond Predef.type_bool in
      begin match sifnot with
        None ->
          let ifso = type_expect env sifso Predef.type_unit in
          rue {
            exp_desc = Texp_ifthenelse(cond, ifso, None);
            exp_loc = loc; exp_extra = [];
            exp_type = ifso.exp_type;
            exp_attributes = sexp.pexp_attributes;
            exp_env = env }
      | Some sifnot ->
          let ifso = type_expect env sifso ty_expected in
          let ifnot = type_expect env sifnot ty_expected in
          (* Keep sharing *)
          unify_exp env ifnot ifso.exp_type;
          re {
            exp_desc = Texp_ifthenelse(cond, ifso, Some ifnot);
            exp_loc = loc; exp_extra = [];
            exp_type = ifso.exp_type;
            exp_attributes = sexp.pexp_attributes;
            exp_env = env }
      end
  | Pexp_sequence(sexp1, sexp2) ->
      let exp1 = type_statement env sexp1 in
      let exp2 = type_expect env sexp2 ty_expected in
      re {
        exp_desc = Texp_sequence(exp1, exp2);
        exp_loc = loc; exp_extra = [];
        exp_type = exp2.exp_type;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_while(scond, sbody) ->
      let cond = type_expect env scond Predef.type_bool in
      let body = type_statement env sbody in
      rue {
        exp_desc = Texp_while(cond, body);
        exp_loc = loc; exp_extra = [];
        exp_type = instance_def Predef.type_unit;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_for(param, slow, shigh, dir, sbody) ->
      let low = type_expect env slow Predef.type_int in
      let high = type_expect env shigh Predef.type_int in
      let id, new_env =
        match param.ppat_desc with
        | Ppat_any -> Ident.create "_for", env
        | Ppat_var {txt} ->
            Env.enter_value txt {val_type = instance_def Predef.type_int;
                                 val_attributes = [];
                                 val_kind = Val_reg; Types.val_loc = loc; } env
              ~check:(fun s -> Warnings.Unused_for_index s)
        | _ ->
            raise (Error (param.ppat_loc, env, Invalid_for_loop_index))
      in
      let body = type_statement new_env sbody in
      rue {
        exp_desc = Texp_for(id, param, low, high, dir, body);
        exp_loc = loc; exp_extra = [];
        exp_type = instance_def Predef.type_unit;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_constraint (sarg, sty) ->
      let separate = true in (* always separate, 1% slowdown for lablgtk *)
      if separate then begin_def ();
      let cty = Typetexp.transl_simple_type env false sty in
      let ty = cty.ctyp_type in
      let (arg, ty') =
        if separate then begin
          end_def ();
          generalize_structure ty;
          (type_argument env sarg ty (instance env ty), instance env ty)
        end else
          (type_argument env sarg ty ty, ty)
      in
      rue {
        exp_desc = arg.exp_desc;
        exp_loc = arg.exp_loc;
        exp_type = ty';
        exp_attributes = arg.exp_attributes;
        exp_env = env;
        exp_extra =
          (Texp_constraint cty, loc, sexp.pexp_attributes) :: arg.exp_extra;
      }
  | Pexp_coerce(sarg, sty, sty') ->
      let separate = true in (* always separate, 1% slowdown for lablgtk *)
      (* Also see PR#7199 for a problem with the following:
         let separate =  Env.has_local_constraints env in*)
      let (arg, ty',cty,cty') =
        match sty with
        | None ->
            let (cty', force) =
              Typetexp.transl_simple_type_delayed env sty'
            in
            let ty' = cty'.ctyp_type in
            if separate then begin_def ();
            let arg = type_exp env sarg in
            let gen =
              if separate then begin
                end_def ();
                let tv = newvar () in
                let gen = generalizable tv.level arg.exp_type in
                (try unify_var env tv arg.exp_type with Unify trace ->
                  raise(Error(arg.exp_loc, env, Expr_type_clash trace)));
                gen
              end else true
            in
            begin match arg.exp_desc, !self_coercion, (repr ty').desc with
            | _ when free_variables ~env arg.exp_type = []
                  && free_variables ~env ty' = [] ->
                if not gen && (* first try a single coercion *)
                  let snap = snapshot () in
                  let ty, _b = enlarge_type env ty' in
                  try
                    force (); Ctype.unify env arg.exp_type ty; true
                  with Unify _ ->
                    backtrack snap; false
                then ()
                else begin try
                  let force' = subtype env arg.exp_type ty' in
                  force (); force' ();
                with Subtype (tr1, tr2) ->
                  (* prerr_endline "coercion failed"; *)
                  raise(Error(loc, env, Not_subtype(tr1, tr2)))
                end;
            | _ ->
                let ty, b = enlarge_type env ty' in
                force ();
                begin try Ctype.unify env arg.exp_type ty with Unify trace ->
                  raise(Error(sarg.pexp_loc, env,
                        Coercion_failure(ty', full_expand env ty', trace, b)))
                end
            end;
            (arg, ty', None, cty')
        | Some sty ->
            if separate then begin_def ();
            let (cty, force) =
              Typetexp.transl_simple_type_delayed env sty
            and (cty', force') =
              Typetexp.transl_simple_type_delayed env sty'
            in
            let ty = cty.ctyp_type in
            let ty' = cty'.ctyp_type in
            begin try
              let force'' = subtype env ty ty' in
              force (); force' (); force'' ()
            with Subtype (tr1, tr2) ->
              raise(Error(loc, env, Not_subtype(tr1, tr2)))
            end;
            if separate then begin
              end_def ();
              generalize_structure ty;
              generalize_structure ty';
              (type_argument env sarg ty (instance env ty),
               instance env ty', Some cty, cty')
            end else
              (type_argument env sarg ty ty, ty', Some cty, cty')
      in
      rue {
        exp_desc = arg.exp_desc;
        exp_loc = arg.exp_loc;
        exp_type = ty';
        exp_attributes = arg.exp_attributes;
        exp_env = env;
        exp_extra = (Texp_coerce (cty, cty'), loc, sexp.pexp_attributes) ::
                       arg.exp_extra;
      }
  | Pexp_send (e, {txt=met}) ->
      let obj = type_exp env e in
      let obj_meths = ref None in
      begin try
        let (meth, exp, typ) =
          match obj.exp_desc with
          | _ ->
              (Tmeth_name met, None,
               filter_method env met Public obj.exp_type)
        in
        let typ =
          match repr typ with
            {desc = Tpoly (ty, [])} ->
              instance env ty
          | {desc = Tpoly (ty, tl); level = _} ->
              snd (instance_poly false tl ty)
          | {desc = Tvar _} as ty ->
              let ty' = newvar () in
              unify env (instance_def ty) (newty(Tpoly(ty',[])));
              (* if not !Clflags.nolabels then
                 Location.prerr_warning loc (Warnings.Unknown_method met); *)
              ty'
          | _ ->
              assert false
        in
        rue {
          exp_desc = Texp_send(obj, meth, exp);
          exp_loc = loc; exp_extra = [];
          exp_type = typ;
          exp_attributes = sexp.pexp_attributes;
          exp_env = env }
      with Unify _ ->
        let valid_methods =
          match !obj_meths with
          | Some meths ->
             Some (Meths.fold (fun meth _meth_ty li -> meth::li) !meths [])
          | None ->
             match (expand_head env obj.exp_type).desc with
             | Tobject (fields, _) ->
                let (fields, _) = Ctype.flatten_fields fields in
                let collect_fields li (meth, meth_kind, _meth_ty) =
                  if meth_kind = Fpresent then meth::li else li in
                Some (List.fold_left collect_fields [] fields)
             | _ -> None
        in
        raise(Error(e.pexp_loc, env,
                    Undefined_method (obj.exp_type, met, valid_methods)))
      end
  | Pexp_new _ 
  | Pexp_setinstvar _ 
  | Pexp_override _ ->
        assert false
  | Pexp_letmodule(name, smodl, sbody) ->
      let ty = newvar() in
      (* remember original level *)
      begin_def ();
      Ident.set_current_time ty.level;
      let context = Typetexp.narrow () in
      let modl = !type_module env smodl in
      let (id, new_env) = Env.enter_module name.txt modl.mod_type env in
      Ctype.init_def(Ident.current_time());
      Typetexp.widen context;
      let body = type_expect new_env sbody ty_expected in
      (* go back to original level *)
      end_def ();
      (* Unification of body.exp_type with the fresh variable ty
         fails if and only if the prefix condition is violated,
         i.e. if generative types rooted at id show up in the
         type body.exp_type.  Thus, this unification enforces the
         scoping condition on "let module". *)
      (* Note that this code will only be reached if ty_expected
         is a generic type variable, otherwise the error will occur
         above in type_expect *)
      begin try
        Ctype.unify_var new_env ty body.exp_type
      with Unify _ ->
        raise(Error(loc, env, Scoping_let_module(name.txt, body.exp_type)))
      end;
      re {
        exp_desc = Texp_letmodule(id, name, modl, body);
        exp_loc = loc; exp_extra = [];
        exp_type = ty;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_letexception(cd, sbody) ->
      let (cd, newenv) = Typedecl.transl_exception env cd in
      let body = type_expect newenv sbody ty_expected in
      re {
        exp_desc = Texp_letexception(cd, body);
        exp_loc = loc; exp_extra = [];
        exp_type = body.exp_type;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }

  | Pexp_assert (e) ->
      let cond = type_expect env e Predef.type_bool in
      let exp_type =
        match cond.exp_desc with
        | Texp_construct(_, {cstr_name="false"}, _) ->
            instance env ty_expected
        | _ ->
            instance_def Predef.type_unit
      in
      rue {
        exp_desc = Texp_assert cond;
        exp_loc = loc; exp_extra = [];
        exp_type;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env;
      }
  | Pexp_lazy e ->
      let ty = newgenvar () in
      let to_unify = Predef.type_lazy_t ty in
      unify_exp_types loc env to_unify ty_expected;
      let arg = type_expect env e ty in
      re {
        exp_desc = Texp_lazy arg;
        exp_loc = loc; exp_extra = [];
        exp_type = instance env ty_expected;
        exp_attributes = sexp.pexp_attributes;
        exp_env = env;
      }
  | Pexp_object _ -> assert false  
  | Pexp_poly(sbody, sty) ->
      let ty, cty =
        match sty with None -> repr ty_expected, None
        | Some sty ->
            let sty = Ast_helper.Typ.force_poly sty in
            let cty = Typetexp.transl_simple_type env false sty in
            repr cty.ctyp_type, Some cty
      in
      if sty <> None then
        unify_exp_types loc env (instance env ty) (instance env ty_expected);
      let exp =
        match (expand_head env ty).desc with
          Tpoly (ty', []) ->
            let exp = type_expect env sbody ty' in
            { exp with exp_type = instance env ty }
        | Tpoly (ty', tl) ->
            (* One more level to generalize locally *)
            begin_def ();
            let vars, ty'' = instance_poly true tl ty' in
            let exp = type_expect env sbody ty'' in
            end_def ();
            check_univars env false "method" exp ty_expected vars;
            { exp with exp_type = instance env ty }
        | Tvar _ ->
            let exp = type_exp env sbody in
            let exp = {exp with exp_type = newty (Tpoly (exp.exp_type, []))} in
            unify_exp env exp ty;
            exp
        | _ -> assert false
      in
      re { exp with exp_extra =
             (Texp_poly cty, loc, sexp.pexp_attributes) :: exp.exp_extra }
  | Pexp_newtype({txt=name}, sbody) ->
      let ty = newvar () in
      (* remember original level *)
      begin_def ();
      (* Create a fake abstract type declaration for name. *)
      let level = get_current_level () in
      let decl = {
        type_params = [];
        type_arity = 0;
        type_kind = Type_abstract;
        type_private = Public;
        type_manifest = None;
        type_variance = [];
        type_newtype_level = Some (level, level);
        type_loc = loc;
        type_attributes = [];
        type_immediate = false;
        type_unboxed = unboxed_false_default_false;
      }
      in
      Ident.set_current_time ty.level;
      let (id, new_env) = Env.enter_type name decl env in
      Ctype.init_def(Ident.current_time());

      let body = type_exp new_env sbody in
      (* Replace every instance of this type constructor in the resulting
         type. *)
      let seen = Hashtbl.create 8 in
      let rec replace t =
        if Hashtbl.mem seen t.id then ()
        else begin
          Hashtbl.add seen t.id ();
          match t.desc with
          | Tconstr (Path.Pident id', _, _) when id == id' -> link_type t ty
          | _ -> Btype.iter_type_expr replace t
        end
      in
      let ety = Subst.type_expr Subst.identity body.exp_type in
      replace ety;
      (* back to original level *)
      end_def ();
      (* lower the levels of the result type *)
      (* unify_var env ty ety; *)

      (* non-expansive if the body is non-expansive, so we don't introduce
         any new extra node in the typed AST. *)
      rue { body with exp_loc = loc; exp_type = ety;
            exp_extra =
            (Texp_newtype name, loc, sexp.pexp_attributes) :: body.exp_extra }
  | Pexp_pack m ->
      let (p, nl) =
        match Ctype.expand_head env (instance env ty_expected) with
          {desc = Tpackage (p, nl, _tl)} ->
            (p, nl)
        | {desc = Tvar _} ->
            raise (Error (loc, env, Cannot_infer_signature))
        | _ ->
            raise (Error (loc, env, Not_a_packed_module ty_expected))
      in
      let (modl, tl') = !type_package env m p nl in
      rue {
        exp_desc = Texp_pack modl;
        exp_loc = loc; exp_extra = [];
        exp_type = newty (Tpackage (p, nl, tl'));
        exp_attributes = sexp.pexp_attributes;
        exp_env = env }
  | Pexp_open (ovf, lid, e) ->
      let (path, newenv) = !type_open ovf env sexp.pexp_loc lid in
      let exp = type_expect newenv e ty_expected in
      { exp with
        exp_extra = (Texp_open (ovf, path, lid, newenv), loc,
                     sexp.pexp_attributes) ::
                      exp.exp_extra;
      }

  | Pexp_extension ({ txt = ("ocaml.extension_constructor"
                             |"extension_constructor"); _ },
                    payload) ->
      begin match payload with
      | PStr [ { pstr_desc =
                   Pstr_eval ({ pexp_desc = Pexp_construct (lid, None); _ }, _)
               } ] ->
          let path =
            match (Typetexp.find_constructor env lid.loc lid.txt).cstr_tag with
            | Cstr_extension (path, _) -> path
            | _ -> raise (Error (lid.loc, env, Not_an_extension_constructor))
          in
          rue {
            exp_desc = Texp_extension_constructor (lid, path);
            exp_loc = loc; exp_extra = [];
            exp_type = instance_def Predef.type_extension_constructor;
            exp_attributes = sexp.pexp_attributes;
            exp_env = env }
      | _ ->
          raise (Error (loc, env, Invalid_extension_constructor_payload))
      end
  | Pexp_extension ext ->
      raise (Error_forward (Builtin_attributes.error_of_extension ext))

  | Pexp_unreachable ->
      re { exp_desc = Texp_unreachable;
           exp_loc = loc; exp_extra = [];
           exp_type = instance env ty_expected;
           exp_attributes = sexp.pexp_attributes;
           exp_env = env }

and type_function ?in_function loc attrs env ty_expected l caselist =
  let (loc_fun, ty_fun) =
    match in_function with Some p -> p
    | None -> (loc, instance env ty_expected)
  in
  let separate = Env.has_local_constraints env in
  if separate then begin_def ();
  let (ty_arg, ty_res) =
    try filter_arrow env (instance env ty_expected) l
    with Unify _ ->
      match expand_head env ty_expected with
        {desc = Tarrow _} as ty ->
          raise(Error(loc, env, Abstract_wrong_label(l, ty)))
      | _ ->
          raise(Error(loc_fun, env,
                      Too_many_arguments (in_function <> None, ty_fun)))
  in
  let ty_arg =
    if is_optional l then
      let tv = newvar() in
      begin
        try unify env ty_arg (type_option tv)
        with Unify _ -> assert false
      end;
      type_option tv
    else ty_arg
  in
  if separate then begin
    end_def ();
    generalize_structure ty_arg;
    generalize_structure ty_res
  end;
  let cases, partial =
    type_cases ~in_function:(loc_fun,ty_fun) env ty_arg ty_res
      true loc caselist in
  if is_optional l && not_function env ty_res then
    Location.prerr_warning (List.hd cases).c_lhs.pat_loc
      Warnings.Unerasable_optional_argument;
  let param = name_pattern "param" cases in
  re {
    exp_desc = Texp_function { arg_label = l; param; cases; partial; };
    exp_loc = loc; exp_extra = [];
    exp_type = instance env (newgenty (Tarrow(l, ty_arg, ty_res, Cok)));
    exp_attributes = attrs;
    exp_env = env }


and type_label_access env srecord lid =
  let record = type_exp ~recarg:Allowed env srecord in
  let ty_exp = record.exp_type in
  let opath =
    try
      let (p0, p, _, _) = extract_concrete_record env ty_exp in
      Some(p0, p)
    with Not_found -> None
  in
  let labels = Typetexp.find_all_labels env lid.loc lid.txt in
  let label =
    wrap_disambiguate "This expression has" ty_exp
      (Label.disambiguate lid env opath) labels in
  (record, label, opath)

(* Typing format strings for printing or reading.
   These formats are used by functions in modules Printf, Format, and Scanf.
   (Handling of * modifiers contributed by Thorsten Ohl.) *)
and type_label_exp create env loc ty_expected
          (lid, label, sarg) =
  (* Here also ty_expected may be at generic_level *)
  begin_def ();
  let separate = Env.has_local_constraints env in
  if separate then (begin_def (); begin_def ());
  let (vars, ty_arg, ty_res) = instance_label true label in
  if separate then begin
    end_def ();
    (* Generalize label information *)
    generalize_structure ty_arg;
    generalize_structure ty_res
  end;
  begin try
    unify env (instance_def ty_res) (instance env ty_expected)
  with Unify trace ->
    raise (Error(lid.loc, env, Label_mismatch(lid.txt, trace)))
  end;
  (* Instantiate so that we can generalize internal nodes *)
  let ty_arg = instance_def ty_arg in
  if separate then begin
    end_def ();
    (* Generalize information merged from ty_expected *)
    generalize_structure ty_arg
  end;
  if label.lbl_private = Private then
    if create then
      raise (Error(loc, env, Private_type ty_expected))
    else
      raise (Error(lid.loc, env, Private_label(lid.txt, ty_expected)));
  let arg =
    let snap = if vars = [] then None else Some (Btype.snapshot ()) in
    let arg = type_argument env sarg ty_arg (instance env ty_arg) in
    end_def ();
    try
      check_univars env (vars <> []) "field value" arg label.lbl_arg vars;
      arg
    with exn when not (is_nonexpansive arg) -> try
      (* Try to retype without propagating ty_arg, cf PR#4862 *)
      may Btype.backtrack snap;
      begin_def ();
      let arg = type_exp env sarg in
      end_def ();
      generalize_expansive env arg.exp_type;
      unify_exp env arg ty_arg;
      check_univars env false "field value" arg label.lbl_arg vars;
      arg
    with Error (_, _, Less_general _) as e -> raise e
    | _ -> raise exn    (* In case of failure return the first error *)
  in
  (lid, label, {arg with exp_type = instance env arg.exp_type})

and type_argument ?recarg env sarg ty_expected' ty_expected =
  (* ty_expected' may be generic *)
  let no_labels ty =
    let ls, tvar = list_labels env ty in
    not tvar && List.for_all (fun x -> x = Nolabel) ls
  in
  let rec is_inferred sexp =
    match sexp.pexp_desc with
      Pexp_ident _ | Pexp_apply _ | Pexp_field _ | Pexp_constraint _
    | Pexp_coerce _ | Pexp_send _ | Pexp_new _ -> true
    | Pexp_sequence (_, e) | Pexp_open (_, _, e) -> is_inferred e
    | Pexp_ifthenelse (_, e1, Some e2) -> is_inferred e1 && is_inferred e2
    | _ -> false
  in
  match expand_head env ty_expected' with
    {desc = Tarrow(Nolabel,ty_arg,ty_res,_); level = _}
    when is_inferred sarg ->
      (* apply optional arguments when expected type is "" *)
      (* we must be very careful about not breaking the semantics *)
      let texp = type_exp env sarg in
      let rec make_args args ty_fun =
        match (expand_head env ty_fun).desc with
        | Tarrow (l,ty_arg,ty_fun,_) when is_optional l ->
            let ty = option_none (instance env ty_arg) sarg.pexp_loc in
            make_args ((l, Some ty) :: args) ty_fun
        | Tarrow (Nolabel,_,ty_res',_) ->
            List.rev args, ty_fun, no_labels ty_res'
        | Tvar _ ->  List.rev args, ty_fun, false
        |  _ -> [], texp.exp_type, false
      in
      let args, ty_fun', simple_res = make_args [] texp.exp_type in
      let texp = {texp with exp_type = instance env texp.exp_type}
      and ty_fun = instance env ty_fun' in
      if not (simple_res || no_labels ty_res) then begin
        unify_exp env texp ty_expected;
        texp
      end else begin
      unify_exp env {texp with exp_type = ty_fun} ty_expected;
      if args = [] then texp else
      (* eta-expand to avoid side effects *)
      let var_pair name ty =
        let id = Ident.create name in
        {pat_desc = Tpat_var (id, mknoloc name); pat_type = ty;pat_extra=[];
         pat_attributes = [];
         pat_loc = Location.none; pat_env = env},
        {exp_type = ty; exp_loc = Location.none; exp_env = env;
         exp_extra = []; exp_attributes = [];
         exp_desc =
         Texp_ident(Path.Pident id, mknoloc (Longident.Lident name),
                    {val_type = ty; val_kind = Val_reg;
                     val_attributes = [];
                     Types.val_loc = Location.none})}
      in
      let eta_pat, eta_var = var_pair "eta" ty_arg in
      let func texp =
        let e =
          {texp with exp_type = ty_res; exp_desc =
           Texp_apply
             (texp,
              args @ [Nolabel, Some eta_var])}
        in
        let cases = [case eta_pat e] in
        let param = name_pattern "param" cases in
        { texp with exp_type = ty_fun; exp_desc =
          Texp_function { arg_label = Nolabel; param; cases;
            partial = Total; } }
      in
      Location.prerr_warning texp.exp_loc
        (Warnings.Eliminated_optional_arguments
           (List.map (fun (l, _) -> Printtyp.string_of_label l) args));
      (* let-expand to have side effects *)
      let let_pat, let_var = var_pair "arg" texp.exp_type in
      re { texp with exp_type = ty_fun; exp_desc =
           Texp_let (Nonrecursive,
                     [{vb_pat=let_pat; vb_expr=texp; vb_attributes=[];
                       vb_loc=Location.none;
                      }],
                     func let_var) }
      end
  | _ ->
      let texp = type_expect ?recarg env sarg ty_expected' in
      unify_exp env texp ty_expected;
      texp

and type_application uncurried env funct (sargs : sargs) : targs * Types.type_expr * bool =
  (* funct.exp_type may be generic *)
  let result_type omitted ty_fun =
    List.fold_left
      (fun ty_fun (l,ty,lv) -> newty2 lv (Tarrow(l,ty,ty_fun,Cok)))
      ty_fun omitted
  in
  let has_label l ty_fun =
    let ls, tvar = list_labels env ty_fun in
    tvar || List.mem l ls
  in
  let ignored = ref [] in
  let has_uncurried_type t =
    match (expand_head env t).desc with
    | Tconstr (Pident {name = "function$"},[t; tArity],_) ->
      let arity = Ast_uncurried.type_to_arity tArity in
      Some (arity, t)
    | _ -> None in
  let force_uncurried_type funct =
    match has_uncurried_type funct.exp_type with
    | None ->
      let arity = List.length sargs in
      let uncurried_typ = Ast_uncurried.make_uncurried_type ~env ~arity (newvar()) in
      begin
        match (expand_head env funct.exp_type).desc with
        | Tvar _ | Tarrow _ ->
          unify_exp env funct uncurried_typ
        | _ ->
          raise(Error(funct.exp_loc, env, Apply_non_function (expand_head env funct.exp_type)))
      end
    | Some _ -> () in
  let extract_uncurried_type t =
    match has_uncurried_type t with
    | Some (arity, t1) ->
      if List.length sargs > arity then
        raise(Error(funct.exp_loc, env,
          Uncurried_arity_mismatch (t, arity, List.length sargs)));
      t1, arity
    | None -> t, max_int in
  let update_uncurried_arity ~nargs t newT =
    match has_uncurried_type t with
    | Some (arity, _) ->
      let newarity = arity - nargs in
      let fully_applied = newarity = 0 in
      if uncurried && not fully_applied then
        raise(Error(funct.exp_loc, env,
          Uncurried_arity_mismatch (t, arity, List.length sargs)));
      let newT = if fully_applied then newT else Ast_uncurried.make_uncurried_type ~env ~arity:newarity newT in
      (fully_applied, newT)
    | _ -> (false, newT)
  in
  let rec type_unknown_args max_arity (args : lazy_args) omitted ty_fun (syntax_args : sargs)
     : targs * _ = 
    match syntax_args with 
    |  [] ->
        (List.map
            (function l, None -> l, None
                | l, Some f -> l, Some (f ()))
           (List.rev args),
         instance env (result_type omitted ty_fun))
    | (l1, sarg1) :: sargl ->
        let (ty1, ty2) =
          let ty_fun = expand_head env ty_fun in
          let arity_ok = List.length args < max_arity in
          match ty_fun.desc with
            Tvar _  ->
              let t1 = newvar () and t2 = newvar () in
              if ty_fun.level >= t1.level && not_identity funct.exp_desc then
                Location.prerr_warning sarg1.pexp_loc Warnings.Unused_argument;
              unify env ty_fun (newty (Tarrow(l1,t1,t2,Clink(ref Cunknown))));
              (t1, t2)
          | Tarrow (l,t1,t2,_) when Asttypes.same_arg_label l l1 && arity_ok
            ->
              (t1, t2)
          | td ->
              let ty_fun =
                match td with Tarrow _ -> newty td | _ -> ty_fun in
              let ty_res = result_type (omitted @ !ignored) ty_fun in
              match ty_res.desc with
                Tarrow _ ->
                  if not arity_ok then
                    raise (Error(sarg1.pexp_loc, env,
                                 Apply_wrong_label(l1, funct.exp_type))) else
                  if (not (has_label l1 ty_fun)) then
                    raise (Error(sarg1.pexp_loc, env,
                                 Apply_wrong_label(l1, ty_res)))
                  else
                    raise (Error(funct.exp_loc, env, Incoherent_label_order))
              | _ ->
                  raise(Error(funct.exp_loc, env, Apply_non_function
                                (expand_head env funct.exp_type)))
        in
        let optional = is_optional l1 in
        let arg1 () =
          let arg1 = type_expect env sarg1 ty1 in
          if optional then
            unify_exp env arg1 (type_option(newvar()));
          arg1
        in
        type_unknown_args max_arity ((l1, Some arg1) :: args) omitted ty2 sargl
  in
  let rec type_args max_arity args omitted ~ty_fun ty_fun0  ~(sargs : sargs)  =
    match expand_head env ty_fun, expand_head env ty_fun0 with
      {desc=Tarrow (l, ty, ty_fun, com); level=lv} ,
      {desc=Tarrow (_, ty0, ty_fun0, _)}
      when (sargs <> [] ) && commu_repr com = Cok && List.length args < max_arity ->
        let name = label_name l
        and optional = is_optional l in
        let sargs, omitted,  arg =          
            match extract_label name sargs with 
            | None ->          
                if optional && label_assoc Nolabel sargs
                then begin
                  ignored := (l,ty,lv) :: !ignored;
                  sargs, omitted , Some (fun () -> option_none (instance env ty) Location.none)
                end else 
                  sargs, (l,ty,lv) :: omitted , None
            | Some (l', sarg0, sargs) ->                   
            if not optional && is_optional l' then
              Location.prerr_warning sarg0.pexp_loc
                (Warnings.Nonoptional_label (Printtyp.string_of_label l));
             sargs, omitted ,            
             Some (
            if not optional || is_optional l' then
               (fun () -> type_argument env sarg0 ty ty0)
            else 
               (fun () -> option_some (type_argument env sarg0
                                             (extract_option_type env ty)
                                             (extract_option_type env ty0))))
        in
        type_args max_arity ((l,arg)::args) omitted ~ty_fun ty_fun0 ~sargs 
    | _ ->
        type_unknown_args max_arity args omitted ty_fun0 sargs (* This is the hot path for non-labeled function*)
  in
  let () =  
    let ls, tvar = list_labels env funct.exp_type in
    if not tvar then
    let labels = Ext_list.filter ls (fun l -> not (is_optional l)) in
    if Ext_list.same_length labels sargs &&
       List.for_all (fun (l,_) -> l = Nolabel) sargs &&
       List.exists (fun l -> l <> Nolabel) labels then
        raise 
          (Error(
          funct.exp_loc, env,
          (Labels_omitted
            (List.map Printtyp.string_of_label
                      (Ext_list.filter labels (fun x -> x <> Nolabel))))))  
  in
  match sargs with
    (* Special case for ignore: avoid discarding warning *)
    [Nolabel, sarg] when is_ignore funct env ->
      let ty_arg, ty_res =
        filter_arrow env (instance env funct.exp_type) Nolabel
      in
      let exp = type_expect env sarg ty_arg in
      begin match (expand_head env exp.exp_type).desc with
      | Tarrow _ ->
          Location.prerr_warning exp.exp_loc Warnings.Partial_application
      | Tvar _ ->
          Delayed_checks.add_delayed_check (fun () -> check_application_result env false exp)
      | _ -> ()
      end;
      ([Nolabel, Some exp], ty_res, false)
  | _ ->
      if uncurried then force_uncurried_type funct;
      let ty, max_arity = extract_uncurried_type funct.exp_type in
      let targs, ret_t = type_args max_arity [] [] ~ty_fun:ty (instance env ty) ~sargs in
      let fully_applied, ret_t =
        update_uncurried_arity funct.exp_type ~nargs:(List.length !ignored + List.length sargs) ret_t in
      targs, ret_t, fully_applied

and type_construct env loc lid sarg ty_expected attrs =
  let opath =
    try
      let (p0, p,_) = extract_concrete_variant env ty_expected in
      Some(p0, p)
    with Not_found -> None
  in
  let constrs = Typetexp.find_all_constructors env lid.loc lid.txt in
  let constr =
    wrap_disambiguate "This variant expression is expected to have" ty_expected
      (Constructor.disambiguate lid env opath) constrs in
  Env.mark_constructor Env.Positive env (Longident.last lid.txt) constr;
  Builtin_attributes.check_deprecated loc constr.cstr_attributes
    constr.cstr_name;
  let sargs =
    match sarg with
      None -> []
    | Some {pexp_desc = Pexp_tuple sel} when
        constr.cstr_arity > 1 || Builtin_attributes.explicit_arity attrs
      -> sel
    | Some se -> [se] in
  if List.length sargs <> constr.cstr_arity then
    raise(Error(loc, env, Constructor_arity_mismatch
                  (lid.txt, constr.cstr_arity, List.length sargs)));
  let separate = Env.has_local_constraints env in
  if separate then (begin_def (); begin_def ());
  let (ty_args, ty_res) = instance_constructor constr in
  let texp =
    re {
      exp_desc = Texp_construct(lid, constr, []);
      exp_loc = loc; exp_extra = [];
      exp_type = ty_res;
      exp_attributes = attrs;
      exp_env = env } in
  if separate then begin
    end_def ();
    generalize_structure ty_res;
    unify_exp env {texp with exp_type = instance_def ty_res}
                  (instance env ty_expected);
    end_def ();
    List.iter generalize_structure ty_args;
    generalize_structure ty_res;
  end;
  let ty_args0, ty_res =
    match instance_list env (ty_res :: ty_args) with
      t :: tl -> tl, t
    | _ -> assert false
  in
  let texp = {texp with exp_type = ty_res} in
  if not separate then unify_exp env texp (instance env ty_expected);
  let recarg =
    match constr.cstr_inlined with
    | None -> Rejected
    | Some _ ->
        begin match sargs with
        | [{pexp_desc =
              Pexp_ident _ |
              Pexp_record (_, (Some {pexp_desc = Pexp_ident _}| None))}] ->
            Required
        | _ ->
            raise (Error(loc, env, Inlined_record_expected))
        end
  in
  let args =
    List.map2 (fun e (t,t0) -> type_argument ~recarg env e t t0) sargs
      (List.combine ty_args ty_args0) in
  if constr.cstr_private = Private then
    raise(Error(loc, env, Private_type ty_res));
  (* NOTE: shouldn't we call "re" on this final expression? -- AF *)
  { texp with
    exp_desc = Texp_construct(lid, constr, args) }

(* Typing of statements (expressions whose values are discarded) *)

and type_statement env sexp =
  let loc = (final_subexpression sexp).pexp_loc in
  begin_def();
  let exp = type_exp env sexp in
  end_def();
  let ty = expand_head env exp.exp_type and tv = newvar() in
  if is_Tvar ty && ty.level > tv.level then
      Location.prerr_warning loc Warnings.Nonreturning_statement;
  let expected_ty = instance_def Predef.type_unit in
  unify_exp env exp expected_ty;
  exp

(* Typing of match cases *)

and type_cases ?in_function env ty_arg ty_res partial_flag loc caselist : _ * Typedtree.partial =
  (* ty_arg is _fully_ generalized *)
  let patterns = List.map (fun {pc_lhs=p} -> p) caselist in
  let contains_polyvars = List.exists contains_polymorphic_variant patterns in
  let erase_either = contains_polyvars && contains_variant_either ty_arg
  and has_gadts = List.exists (contains_gadt env) patterns in
(*  prerr_endline ( if has_gadts then "contains gadt" else "no gadt"); *)
  let ty_arg =
    if (has_gadts || erase_either) 
    then correct_levels ty_arg else ty_arg
  and ty_res, env =
    if has_gadts then
      correct_levels ty_res, duplicate_ident_types caselist env
    else ty_res, env
  in
  let rec is_var spat =
    match spat.ppat_desc with
      Ppat_any | Ppat_var _ -> true
    | Ppat_alias (spat, _) -> is_var spat
    | _ -> false in
  let needs_exhaust_check =
    match caselist with
      [{pc_rhs = {pexp_desc = Pexp_unreachable}}] -> true
    | [{pc_lhs}] when is_var pc_lhs -> false
    | _ -> true
  in
  let init_env () =
    (* raise level for existentials *)
    begin_def ();
    Ident.set_current_time (get_current_level ());
    let lev = Ident.current_time () in
    Ctype.init_def (lev+1000);                 (* up to 1000 existentials *)
    (lev, Env.add_gadt_instance_level lev env)
  in
  let lev, env =
    if has_gadts then init_env () else (get_current_level (), env)
  in
(*  if has_gadts then
    Format.printf "lev = %d@.%a@." lev Printtyp.raw_type_expr ty_res; *)
  (* Do we need to propagate polymorphism *)
  let propagate =
     has_gadts || (repr ty_arg).level = generic_level ||
    match caselist with
      [{pc_lhs}] when is_var pc_lhs -> false
    | _ -> true in
  if propagate then begin_def (); (* propagation of the argument *)
  let pattern_force = ref [] in
(*  Format.printf "@[%i %i@ %a@]@." lev (get_current_level())
    Printtyp.raw_type_expr ty_arg; *)
  let pat_env_list =
    List.map
      (fun {pc_lhs; pc_guard; pc_rhs} ->
        let loc =
          let open Location in
          match pc_guard with
          | None -> pc_rhs.pexp_loc
          | Some g -> {pc_rhs.pexp_loc with loc_start=g.pexp_loc.loc_start}
        in
        let scope = Some (Annot.Idef loc) in
        let (pat, ext_env, force, unpacks) =
          let partial =
            if  erase_either
            then Some false else None in
          let ty_arg = instance ?partial env ty_arg in
          type_pattern ~lev env pc_lhs scope ty_arg
        in
        pattern_force := force @ !pattern_force;
        (pat, (ext_env, unpacks)))
      caselist in
  (* Unify all cases (delayed to keep it order-free) *)
  let ty_arg' = newvar () in
  let unify_pats ty =
    List.iter (fun (pat, (ext_env, _)) -> unify_pat ext_env pat ty)
      pat_env_list in
  unify_pats ty_arg';
  (* Check for polymorphic variants to close *)
  let patl = List.map fst pat_env_list in
  if List.exists has_variants patl then begin
    Parmatch.pressure_variants env patl;
    List.iter (iter_pattern finalize_variant) patl
  end;
  (* `Contaminating' unifications start here *)
  List.iter (fun f -> f()) !pattern_force;
  (* Post-processing and generalization *)
  if propagate || erase_either then unify_pats (instance env ty_arg);
  if propagate then begin
    List.iter
      (iter_pattern (fun {pat_type=t} -> unify_var env t (newvar()))) patl;
    end_def ();
    List.iter (iter_pattern (fun {pat_type=t} -> generalize t)) patl;
  end;
  (* type bodies *)
  let in_function = if List.length caselist = 1 then in_function else None in
  let cases =
    List.map2
      (fun (pat, (ext_env, unpacks)) {pc_lhs; pc_guard; pc_rhs} ->
        let sexp = wrap_unpacks pc_rhs unpacks in
        let ty_res' =
          if contains_gadt env pc_lhs then correct_levels ty_res
          else ty_res in
(*        Format.printf "@[%i %i, ty_res' =@ %a@]@." lev (get_current_level())
          Printtyp.raw_type_expr ty_res'; *)
        let guard =
          match pc_guard with
          | None -> None
          | Some scond ->
              Some
                (type_expect ext_env (wrap_unpacks scond unpacks)
                   Predef.type_bool)
        in
        let exp = type_expect ?in_function ext_env sexp ty_res' in
        {
         c_lhs = pat;
         c_guard = guard;
         c_rhs = {exp with exp_type = instance env ty_res'}
        }
      )
      pat_env_list caselist
  in
  if has_gadts then begin
    let ty_res' = instance env ty_res in
    List.iter (fun c -> unify_exp env c.c_rhs ty_res') cases
  end;
  let do_init = has_gadts || needs_exhaust_check in
  let lev, env =
    if do_init && not has_gadts then init_env () else lev, env in
  let ty_arg_check =
    if do_init then
      (* Hack: use for_saving to copy variables too *)
      Subst.type_expr (Subst.for_saving Subst.identity) ty_arg
    else ty_arg
  in
  let partial =
    if partial_flag then
      check_partial ~lev env ty_arg_check loc cases
    else
      Partial
  in
  let unused_check () =
    List.iter (fun (pat, (env, _)) -> check_absent_variant env pat)
      pat_env_list;
    check_unused ~lev env (instance env ty_arg_check) cases ;
    Parmatch.check_ambiguous_bindings cases
  in
  if contains_polyvars || do_init then
    Delayed_checks.add_delayed_check unused_check
  else
    unused_check ();
  (* Check for unused cases, do not delay because of gadts *)
  if do_init then begin
    end_def ();
    (* Ensure that existential types do not escape *)
    unify_exp_types loc env (instance env ty_res) (newvar ()) ;
  end;
  cases, partial

(* Typing of let bindings *)

and type_let ?(check = fun s -> Warnings.Unused_var s)
             ?(check_strict = fun s -> Warnings.Unused_var_strict s)
    env rec_flag spat_sexp_list scope allow =
  begin_def();
  let is_fake_let =
    match spat_sexp_list with
    | [{pvb_expr={pexp_desc=Pexp_match(
           {pexp_desc=Pexp_ident({ txt = Longident.Lident "*opt*"})},_)}}] ->
        true (* the fake let-declaration introduced by fun ?(x = e) -> ... *)
    | _ ->
        false
  in
  let check = if is_fake_let then check_strict else check in

  let spatl =
    List.map
      (fun {pvb_pat=spat; pvb_attributes=attrs} ->
        attrs, spat)
      spat_sexp_list in
  let nvs = List.map (fun _ -> newvar ()) spatl in
  let (pat_list, new_env, force, unpacks) =
    type_pattern_list env spatl scope nvs allow in
  let attrs_list = List.map fst spatl in
  let is_recursive = (rec_flag = Recursive) in
  (* If recursive, first unify with an approximation of the expression *)
  if is_recursive then
    List.iter2
      (fun pat binding ->
        let pat =
          match pat.pat_type.desc with
          | Tpoly (ty, tl) ->
              {pat with pat_type =
               snd (instance_poly ~keep_names:true false tl ty)}
          | _ -> pat
        in unify_pat env pat (type_approx env binding.pvb_expr))
      pat_list spat_sexp_list;
  (* Polymorphic variant processing *)
  List.iter
    (fun pat ->
      if has_variants pat then begin
        Parmatch.pressure_variants env [pat];
        iter_pattern finalize_variant pat
      end)
    pat_list;
  (* Only bind pattern variables after generalizing *)
  List.iter (fun f -> f()) force;
  let exp_env =
    if is_recursive then new_env else env in

  let current_slot = ref None in
  let rec_needed = ref false in
  let warn_about_unused_bindings =
    List.exists
      (fun attrs ->
         Builtin_attributes.warning_scope ~ppwarning:false attrs (fun () ->
           Warnings.is_active (check "") || Warnings.is_active (check_strict "") ||
           (is_recursive && (Warnings.is_active Warnings.Unused_rec_flag))))
      attrs_list
  in
  let pat_slot_list =
    (* Algorithm to detect unused declarations in recursive bindings:
       - During type checking of the definitions, we capture the 'value_used'
         events on the bound identifiers and record them in a slot corresponding
         to the current definition (!current_slot).
         In effect, this creates a dependency graph between definitions.

       - After type checking the definition (!current_slot = None),
         when one of the bound identifier is effectively used, we trigger
         again all the events recorded in the corresponding slot.
         The effect is to traverse the transitive closure of the graph created
         in the first step.

       We also keep track of whether *all* variables in a given pattern
       are unused. If this is the case, for local declarations, the issued
       warning is 26, not 27.
     *)
    List.map2
      (fun attrs pat ->
         Builtin_attributes.warning_scope ~ppwarning:false attrs (fun () ->
           if not warn_about_unused_bindings then pat, None
           else
             let some_used = ref false in
             (* has one of the identifier of this pattern been used? *)
             let slot = ref [] in
             List.iter
               (fun id ->
                  let vd = Env.find_value (Path.Pident id) new_env in
                  (* note: Env.find_value does not trigger the value_used event *)
                  let name = Ident.name id in
                  let used = ref false in
                  if not (name = "" || name.[0] = '_' || name.[0] = '#') then
                    Delayed_checks.add_delayed_check
                      (fun () ->
                         if not !used then
                           Location.prerr_warning vd.Types.val_loc
                             ((if !some_used then check_strict else check) name)
                      );
                  Env.set_value_used_callback
                    name vd
                    (fun () ->
                       match !current_slot with
                       | Some slot ->
                         slot := (name, vd) :: !slot; rec_needed := true
                       | None ->
                         List.iter
                           (fun (name, vd) -> Env.mark_value_used env name vd)
                           (get_ref slot);
                         used := true;
                         some_used := true
                    )
               )
               (Typedtree.pat_bound_idents pat);
             pat, Some slot
         ))
      attrs_list
      pat_list
  in
  let exp_list =
    List.map2
      (fun {pvb_expr=sexp; pvb_attributes; _} (pat, slot) ->
        let sexp =
          if rec_flag = Recursive then wrap_unpacks sexp unpacks else sexp in
        if is_recursive then current_slot := slot;
        match pat.pat_type.desc with
        | Tpoly (ty, tl) ->
            begin_def ();
            let vars, ty' = instance_poly ~keep_names:true true tl ty in
            let exp =
              Builtin_attributes.warning_scope pvb_attributes
                  (fun () -> type_expect exp_env sexp ty')
            in
            end_def ();
            check_univars env true "definition" exp pat.pat_type vars;
            {exp with exp_type = instance env exp.exp_type}
        | _ ->
            Builtin_attributes.warning_scope pvb_attributes (fun () ->
              type_expect exp_env sexp pat.pat_type))
      spat_sexp_list pat_slot_list in
  current_slot := None;
  if is_recursive && not !rec_needed
  && Warnings.is_active Warnings.Unused_rec_flag then begin
    let {pvb_pat; pvb_attributes} = List.hd spat_sexp_list in
    (* See PR#6677 *)
    Builtin_attributes.warning_scope ~ppwarning:false pvb_attributes
      (fun () ->
         Location.prerr_warning pvb_pat.ppat_loc Warnings.Unused_rec_flag
      )
  end;
  List.iter2
    (fun pat (attrs, exp) ->
       Builtin_attributes.warning_scope ~ppwarning:false attrs
         (fun () ->
            ignore(check_partial env pat.pat_type pat.pat_loc
                     [case pat exp])
         )
    )
    pat_list
    (List.map2 (fun (attrs, _) e -> attrs, e) spatl exp_list);
  end_def();
  List.iter2
    (fun pat exp ->
       if not (is_nonexpansive exp) then
         iter_pattern (fun pat -> generalize_expansive env pat.pat_type) pat)
    pat_list exp_list;
  List.iter
    (fun pat -> iter_pattern (fun pat -> generalize pat.pat_type) pat)
    pat_list;
  let l = List.combine pat_list exp_list in
  let l =
    List.map2
      (fun (p, e) pvb ->
        {vb_pat=p; vb_expr=e; vb_attributes=pvb.pvb_attributes;
         vb_loc=pvb.pvb_loc;
        })
      l spat_sexp_list
  in
  if is_recursive then
    List.iter 
      (fun {vb_pat=pat} -> match pat.pat_desc with
           Tpat_var _ -> ()
         | Tpat_alias ({pat_desc=Tpat_any}, _, _) -> ()
         | _ -> raise(Error(pat.pat_loc, env, Illegal_letrec_pat)))
      l;
  (l, new_env, unpacks)

(* Typing of toplevel bindings *)

let type_binding env rec_flag spat_sexp_list scope =
  Typetexp.reset_type_variables();
  let (pat_exp_list, new_env, _unpacks) =
    type_let
      ~check:(fun s -> Warnings.Unused_value_declaration s)
      ~check_strict:(fun s -> Warnings.Unused_value_declaration s)
      env rec_flag spat_sexp_list scope false
  in
  (pat_exp_list, new_env)

let type_let env rec_flag spat_sexp_list scope =
  let (pat_exp_list, new_env, _unpacks) =
    type_let env rec_flag spat_sexp_list scope false in
  (pat_exp_list, new_env)

(* Typing of toplevel expressions *)

let type_expression env sexp =
  Typetexp.reset_type_variables();
  begin_def();
  let exp = type_exp env sexp in
  if Warnings.is_active Bs_toplevel_expression_unit then 
    (try unify env exp.exp_type 
      (instance_def Predef.type_unit) with 
    | Unify _ 
    | Tags _  -> Location.prerr_warning sexp.pexp_loc Bs_toplevel_expression_unit);
  end_def();
  if not (is_nonexpansive exp) then generalize_expansive env exp.exp_type;
  generalize exp.exp_type;
  match sexp.pexp_desc with
    Pexp_ident lid ->
      (* Special case for keeping type variables when looking-up a variable *)
      let (_path, desc) = Env.lookup_value lid.txt env in
      {exp with exp_type = desc.val_type}
  | _ -> exp

(* Error report *)

let spellcheck ppf unbound_name valid_names =
  Misc.did_you_mean ppf (fun () ->
    Misc.spellcheck valid_names unbound_name
  )

let spellcheck_idents ppf unbound valid_idents =
  spellcheck ppf (Ident.name unbound) (List.map Ident.name valid_idents)

open Format
open Printtyp

let report_error env ppf = function
  | Polymorphic_label lid ->
      fprintf ppf "@[The record field %a is polymorphic.@ %s@]"
        longident lid "You cannot instantiate it in a pattern."
  | Constructor_arity_mismatch(lid, expected, provided) ->
      fprintf ppf
       "@[The constructor %a@ expects %i argument(s),@ \
        but is applied here to %i argument(s)@]"
       longident lid expected provided
  | Label_mismatch(lid, trace) ->
      report_unification_error ppf env trace
        (function ppf ->
           fprintf ppf "The record field %a@ belongs to the type"
                   longident lid)
        (function ppf ->
           fprintf ppf "but is mixed here with fields of type")
  | Pattern_type_clash trace ->
      report_unification_error ppf env trace
        (function ppf ->
          fprintf ppf "This pattern matches values of type")
        (function ppf ->
          fprintf ppf "but a pattern was expected which matches values of type")
  | Or_pattern_type_clash (id, trace) ->
      report_unification_error ppf env trace
        (function ppf ->
          fprintf ppf "The variable %s on the left-hand side of this \
                       or-pattern has type" (Ident.name id))
        (function ppf ->
          fprintf ppf "but on the right-hand side it has type")
  | Multiply_bound_variable name ->
      fprintf ppf "Variable %s is bound several times in this matching" name
  | Orpat_vars (id, valid_idents) ->
      fprintf ppf "Variable %s must occur on both sides of this | pattern"
        (Ident.name id);
      spellcheck_idents ppf id valid_idents
  | Expr_type_clash ( 
      (_, {desc = Tconstr (Pdot (Pdot(Pident {name = "Js_OO"},"Meth",_),a,_),_,_)}) ::
      (_, {desc = Tconstr (Pdot (Pdot(Pident {name = "Js_OO"},"Meth",_),b,_),_,_)}) :: _
   ) when a <> b -> 
      fprintf ppf "This method has %s but was expected %s" a b 

  | Expr_type_clash trace ->
      report_unification_error ppf env trace
        (function ppf ->
           fprintf ppf "This expression has type")
        (function ppf ->
           fprintf ppf "but an expression was expected of type")
  | Apply_non_function typ ->
      reset_and_mark_loops typ;
      begin match (repr typ).desc with
        Tarrow _ ->
          fprintf ppf "@[<v>@[<2>This function has type@ %a@]"
            type_expr typ;
          fprintf ppf "@ @[It is applied to too many arguments;@ %s@]@]"
                      "maybe you forgot a `;'."
      | _ ->
          fprintf ppf "@[<v>@[<2>This expression has type@ %a@]@ %s@]"
            type_expr typ
            "This is not a function; it cannot be applied."
      end
  | Apply_wrong_label (l, ty) ->
      let print_label ppf = function
        | Nolabel -> fprintf ppf "without label"
        | l ->
            fprintf ppf "with label %s" (prefixed_label_name l)
      in
      reset_and_mark_loops ty;
      fprintf ppf
        "@[<v>@[<2>The function applied to this argument has type@ %a@]@.\
          This argument cannot be applied %a@]"
        type_expr ty print_label l
  | Label_multiply_defined s ->
      fprintf ppf "The record field label %s is defined several times" s
  | Labels_missing labels ->
      let print_labels ppf =
        List.iter (fun lbl -> fprintf ppf "@ %s" ( lbl)) in
      fprintf ppf "@[<hov>Some required record fields are missing:%a. If this is a component, add the missing props.@]"
        print_labels labels
  | Label_not_mutable lid ->
      fprintf ppf "The record field %a is not mutable" longident lid
  | Wrong_name (eorp, ty, kind, p, name, valid_names) ->
      reset_and_mark_loops ty;
      if Path.is_constructor_typath p then begin
        fprintf ppf "@[The field %s is not part of the record \
                     argument for the %a constructor@]"
          name
          path p;
      end else begin
      fprintf ppf "@[@[<2>%s type@ %a@]@ "
        eorp type_expr ty;
      fprintf ppf "The %s %s does not belong to type %a@]"
        (label_of_kind kind)
        name (*kind*) path p;
       end;
      spellcheck ppf name valid_names;
  | Name_type_mismatch (kind, lid, tp, tpl) ->
      let name = label_of_kind kind in
      report_ambiguous_type_error ppf env tp tpl
        (function ppf ->
           fprintf ppf "The %s %a@ belongs to the %s type"
             name longident lid kind)
        (function ppf ->
           fprintf ppf "The %s %a@ belongs to one of the following %s types:"
             name longident lid kind)
        (function ppf ->
           fprintf ppf "but a %s was expected belonging to the %s type"
             name kind)
  | Undefined_method (ty, me, valid_methods) ->
      reset_and_mark_loops ty;
      fprintf ppf
        "@[<v>@[This expression has type@;<1 2>%a@]@,\
         It has no field %s@]" type_expr ty me;
      begin match valid_methods with
        | None -> ()
        | Some valid_methods -> spellcheck ppf me valid_methods
      end
  | Not_subtype(tr1, tr2) ->
      report_subtyping_error ppf env tr1 "is not a subtype of" tr2
  | Coercion_failure (ty, ty', trace, b) ->
      report_unification_error ppf env trace
        (function ppf ->
           let ty, ty' = prepare_expansion (ty, ty') in
           fprintf ppf
             "This expression cannot be coerced to type@;<1 2>%a;@ it has type"
           (type_expansion ty) ty')
        (function ppf ->
           fprintf ppf "but is here used with type");
      if b then
        fprintf ppf ".@.@[<hov>%s@ %s@]"
          "This simple coercion was not fully general."
          "Consider using a double coercion."
  | Too_many_arguments (in_function, ty) ->
      reset_and_mark_loops ty;
      if in_function then begin
        fprintf ppf "This function expects too many arguments,@ ";
        fprintf ppf "it should have type@ %a"
          type_expr ty
      end else begin
        fprintf ppf "This expression should not be a function,@ ";
        fprintf ppf "the expected type is@ %a"
          type_expr ty
      end
  | Abstract_wrong_label (l, ty) ->
      let label_mark = function
        | Nolabel -> "but its first argument is not labelled"
        | l -> sprintf "but its first argument is labelled %s"
                       (prefixed_label_name l) in
      reset_and_mark_loops ty;
      fprintf ppf "@[<v>@[<2>This function should have type@ %a@]@,%s@]"
      type_expr ty (label_mark l)
  | Scoping_let_module(id, ty) ->
      reset_and_mark_loops ty;
      fprintf ppf
       "This `let module' expression has type@ %a@ " type_expr ty;
      fprintf ppf
       "In this type, the locally bound module name %s escapes its scope" id
  | Private_type ty ->
      fprintf ppf "Cannot create values of the private type %a" type_expr ty
  | Private_label (lid, ty) ->
      fprintf ppf "Cannot assign field %a of the private type %a"
        longident lid type_expr ty
  | Not_a_variant_type lid ->
      fprintf ppf "The type %a@ is not a variant type" longident lid
  | Incoherent_label_order ->
      fprintf ppf "This labeled function is applied to arguments@ ";
      fprintf ppf "in an order different from other calls.@ ";
      fprintf ppf "This is only allowed when the real type is known."
  | Less_general (kind, trace) ->
      report_unification_error ppf env trace
        (fun ppf -> fprintf ppf "This %s has type" kind)
        (fun ppf -> fprintf ppf "which is less general than")
  | Modules_not_allowed ->
      fprintf ppf "Modules are not allowed in this pattern."
  | Cannot_infer_signature ->
      fprintf ppf
        "The signature for this packaged module couldn't be inferred."
  | Not_a_packed_module ty ->
      fprintf ppf
        "This expression is packed module, but the expected type is@ %a"
        type_expr ty
  | Recursive_local_constraint trace ->
      report_unification_error ppf env trace
        (function ppf ->
           fprintf ppf "Recursive local constraint when unifying")
        (function ppf ->
           fprintf ppf "with")
  | Unexpected_existential ->
      fprintf ppf
        "Unexpected existential"
  | Unqualified_gadt_pattern (tpath, name) ->
      fprintf ppf "@[The GADT constructor %s of type %a@ %s.@]"
        name path tpath
        "must be qualified in this pattern"
  | Invalid_interval ->
      fprintf ppf "@[Only character intervals are supported in patterns.@]"
  | Invalid_for_loop_index ->
      fprintf ppf
        "@[Invalid for-loop index: only variables and _ are allowed.@]"
  | No_value_clauses ->
      fprintf ppf
        "None of the patterns in this 'match' expression match values."
  | Exception_pattern_below_toplevel ->
      fprintf ppf
        "@[Exception patterns must be at the top level of a match case.@]"
  | Inlined_record_escape ->
      fprintf ppf
        "@[This form is not allowed as the type of the inlined record could \
         escape.@]"
  | Inlined_record_expected ->
      fprintf ppf
        "@[This constructor expects an inlined record argument.@]"
  | Unrefuted_pattern pat ->
      fprintf ppf
        "@[%s@ %s@ %a@]"
        "This match case could not be refuted."
        "Here is an example of a value that would reach it:"
        Parmatch.top_pretty pat
  | Invalid_extension_constructor_payload ->
      fprintf ppf
        "Invalid [%%extension_constructor] payload, a constructor is expected."
  | Not_an_extension_constructor ->
      fprintf ppf
        "This constructor is not an extension constructor."
  | Literal_overflow ty ->
      fprintf ppf "Integer literal exceeds the range of representable \
                   integers of type %s" ty
  | Unknown_literal (n, m) ->
      fprintf ppf "Unknown modifier '%c' for literal %s%c" m n m
  | Illegal_letrec_pat ->
      fprintf ppf
        "Only variables are allowed as left-hand side of `let rec'"
  | Labels_omitted labels ->
      fprintf ppf  "For labeled function, labels %s were omitted in the application of this function." 
      (String.concat ", " labels)  
  | Empty_record_literal ->
      fprintf ppf  "Empty record literal {} should be type annotated or used in a record context."
  | Uncurried_arity_mismatch (typ, arity, args) ->
    fprintf ppf "@[<v>@[<2>This uncurried function has type@ %a@]"
    type_expr typ;
    fprintf ppf "@ @[It is applied with @{<error>%d@} argument%s but it requires @{<info>%d@}.@]@]"
      args (if args = 0 then "" else "s") arity
  | Field_not_optional (name, typ) ->
    fprintf ppf
    "Field @{<info>%s@} is not optional in type %a. Use without ?" name
    type_expr typ


let super_report_error_no_wrap_printing_env = report_error


let report_error env ppf err =
  wrap_printing_env env (fun () -> report_error env ppf err)

let () =
  Location.register_error_of_exn
    (function
      | Error (loc, env, err) ->
        Some (Location.error_of_printer loc (report_error env) err)
      | Error_forward err ->
        Some err
      | _ ->
        None
    )


(* drop ?recarg argument from the external API *)
let type_expect ?in_function env e ty = type_expect ?in_function env e ty
let type_exp env e = type_exp env e
let type_argument env e t1 t2 = type_argument env e t1 t2
