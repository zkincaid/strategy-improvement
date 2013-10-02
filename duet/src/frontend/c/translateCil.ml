(** Utilities for translating from Cil's IR to ours *)

open Core
open Expr
open Apak
open Pretty
open Ast

(* ========================================================================== *)
(* CIL->CIL simplification pass.  The interesting function here is just
   "simplify". *)

(* Unique label id's for switch statments *)
let label_id = ref 0
let mk_label loc =
  begin
    label_id := !label_id + 1;
    Cil.Label ("__switch_" ^ (string_of_int (!label_id)), loc, false)
  end

(* replace breaks with goto target *)
class breakVisitor target = object (self)
  inherit Cil.nopCilVisitor
  method vstmt stmt =
    let open Cil in
    match stmt.skind with
    | Break loc ->
      stmt.skind <- Goto (ref target, loc);
      ChangeTo stmt

    (* don't descend into switches and loops; break target goes out of
       scope *)
    | Switch _ -> SkipChildren
    | Loop _ -> SkipChildren
    | _ -> DoChildren
end

(* replace continues with goto target *)
class continueVisitor target = object (self)
  inherit Cil.nopCilVisitor
  method vstmt stmt =
    let open Cil in
    match stmt.skind with
    | Continue loc ->
      stmt.skind <- Goto(ref target, loc);
      ChangeTo stmt
    | Loop _ -> SkipChildren
    | _ -> DoChildren
end

class loopVisitor = object (self)
  inherit Cil.nopCilVisitor
  method vstmt stmt =
    let open Cil in
    let break_target = mkEmptyStmt () in
    let cont_target = mkEmptyStmt () in
    let break_target_label = mk_label locUnknown in
    let cont_target_label = mk_label locUnknown in
    match stmt.skind with
    | Loop (bl, loc, st1, st2) ->
      let block = visitCilBlock (new breakVisitor break_target) bl in
      let cblock =
	visitCilBlock (new continueVisitor cont_target) block
      in
      let kind = Block (mkBlock [cont_target;
                                 (mkStmt (Block cblock));
                                 mkStmt (Goto (ref cont_target, loc));
                                 break_target])
      in
      break_target.labels <- [break_target_label];
      cont_target.labels <- [cont_target_label];
      stmt.skind <- kind;
      ChangeDoChildrenPost (stmt, fun x -> x)
    | _ -> DoChildren
end

(* Replace switches with ifs/gotos *)
class switchVisitor = object (self)
  inherit Cil.nopCilVisitor
  method vstmt stmt =
    let open Cil in
    (* Replace case and default labels with regular labels, and build a list
       of targets.  Targets are (stmt, exp option) pairs, where stmt is the
       statment labeled by the case, and the expression is the value attached
       to that case (None for default labels) *)
    let replace_cases stmt =
      let targets = ref [] in
      let add_target exp = targets := (stmt, exp)::(!targets) in
      let f lbl = match lbl with
        | Label _        -> lbl
        | Case (exp,loc) -> add_target (Some exp); mk_label loc
        | Default loc    -> add_target None; mk_label loc
      in
      stmt.labels <- List.map f stmt.labels;
      !targets
    in

    (* Build branches for targets, falling through to rest if the case does
       not hold.  *)
    let mk_if exp target rest = match target with
      | (stmt, None) ->
	(* Default case.  Throw out rest, insert unconditional goto *)
	mkStmt (Goto (ref stmt, locUnknown))
      | (stmt, Some e) ->
        mkStmt (If (BinOp (Eq, exp, e, typeOf exp),
                    mkBlock [mkStmt (Goto (ref stmt, locUnknown))],
                    mkBlock [rest],
                    locUnknown))
    in
    match stmt.skind with
    | Switch (exp, block, stmts, loc) ->
      let break_target = mkEmptyStmt () in
      let block = visitCilBlock (new breakVisitor break_target) block in
      let targets = List.concat (List.map replace_cases block.bstmts) in
      let break_target_label = mk_label locUnknown in
      let branching =
        List.fold_right (mk_if exp) targets (mkEmptyStmt ())
      in
      let kind =  Block (mkBlock [branching;
                                  mkStmt (Block block);
                                  break_target])
      in
      break_target.labels <- [break_target_label];
      stmt.skind <- kind;
      ChangeDoChildrenPost (stmt, fun x -> x)
    | _ -> DoChildren

end

let simplify file =
  if (not !Epicenter.doEpicenter) then Rmtmps.removeUnusedTemps file;
  Cil.iterGlobals file (fun glob -> match glob with
  | Cil.GFun(fd,_) -> Oneret.oneret fd;
  | _ -> ());
  let file = Simplemem.simplemem file in

  Cil.visitCilFile (new loopVisitor) file;
  Cil.visitCilFile (new switchVisitor) file;
  Cfg.clearFileCFG file;
  Cfg.computeFileCFG file


(* ========================================================================== *)
(* misc *)

(* Givin a CIL expr, calculate the integer value of the expression as int *)
exception Not_constant of string
let calc_expr x =
  match Cil.constFold true x with
    | Cil.Const Cil.CInt64 (i, _, _) -> Int64.to_int i
    | exp -> raise (Not_constant (Pretty.sprint 79 (Cil.d_exp () exp)))

let type_size t = calc_expr (Cil.SizeOf t)

(* Calculate the offset of a field within a struct or union *)
let field_offset fi =
  let comp_typ = Cil.TComp (fi.Cil.fcomp, []) in
  let (bits_offset, _) =
    Cil.bitsOffset comp_typ (Cil.Field (fi, Cil.NoOffset))
  in
    if bits_offset mod 8 = 0 then bits_offset / 8
    else bits_offset/8
(* failwith "fe/c: Can't calculate offsets for bitfields"*)

(* ========================================================================== *)
(** Types *)

(* Hash table that maps named types to their underlying types  *)
module HT = Hashtbl
let named_hash = HT.create 32

(* converts the interger type of CIL to our int_kind *)
let ik_of_ikind = function
  | Cil.IChar       -> IChar
  | Cil.ISChar      -> IChar
  | Cil.IUChar      -> IChar
  | Cil.IBool       -> IBool
  | Cil.IInt        -> IInt
  | Cil.IUInt       -> IInt
  | Cil.IShort      -> IShort
  | Cil.IUShort     -> IShort
  | Cil.ILong       -> ILong
  | Cil.IULong      -> ILong
  | Cil.ILongLong   -> ILongLong
  | Cil.IULongLong  -> ILongLong

(* converts the floating point type of CIL to our float_kind *)
let fk_of_fkind = function
  | Cil.FFloat      -> FFloat
  | Cil.FDouble     -> FDouble
  | Cil.FLongDouble -> FLongDouble

(** Converts a Cil.typ to our internal representation. *)
let rec tr_typ cil_typ =
  match cil_typ with
    | Cil.TNamed (tinfo, _) ->
	(match tinfo.Cil.ttype with
	   | Cil.TComp (cinfo, _) ->
	       if (tinfo.Cil.tname = "pthread_mutex_t"
		   || tinfo.Cil.tname = "spin_lock_t")
	       then Concrete Lock
	       else Named (tinfo.Cil.tname, ref (tr_ctyp tinfo.Cil.ttype))
	   | typ -> Concrete (tr_ctyp typ)) (* only allow aliases for
					       record types *)
    | _ -> Concrete (tr_ctyp cil_typ)
and tr_ctyp =
  let tr_field f =
    { finame = f.Cil.fname;
      fityp = tr_typ f.Cil.ftype;
      fioffset = field_offset f;
    }
  in
  let tr_enumi (s,e,_) = (s, calc_expr e) in
    function
      | Cil.TVoid _ -> Void
      | Cil.TInt (ik, _) -> Int (ik_of_ikind ik)
      | Cil.TFloat (fk, _) -> Float (fk_of_fkind fk)
      | Cil.TPtr (base, _) -> Pointer (tr_typ base)
      | Cil.TArray (base, None, _) -> Array (tr_typ base, None)
      | Cil.TArray (base, Some expr, _) ->
	  Array (tr_typ base, Some (calc_expr expr))
      | Cil.TEnum (en, _) ->
	  Enum {enname = en.Cil.ename;
		enitems = List.map tr_enumi en.Cil.eitems}
      | Cil.TFun (typ, None, bool, _) -> Dynamic
      | Cil.TFun (typ, Some args, bool, _) ->
	  Func (tr_typ typ,
		List.map (fun (_,t,_) -> tr_typ t) args)
      | Cil.TBuiltin_va_list _ -> Dynamic (* todo *)
      | Cil.TNamed (tinfo, _) -> tr_ctyp tinfo.Cil.ttype
      | Cil.TComp (cinfo, _) ->
	  try resolve_type (HT.find named_hash cinfo.Cil.ckey)
	  with Not_found -> begin
	    let typ_ref = ref Void in
	    let named_typ = Named (cinfo.Cil.cname, typ_ref) in
	      HT.add named_hash cinfo.Cil.ckey named_typ;
	      let record_info =
		{ rfields = List.map tr_field cinfo.Cil.cfields;
		  rkey = cinfo.Cil.ckey;
		  rname = cinfo.Cil.cname; }
	      in
	      let typ =
		if cinfo.Cil.cstruct then Record record_info
		else Union record_info
	      in
		typ_ref := typ;
		typ
	  end

let type_of_var v = tr_typ v.Cil.vtype


(* ========================================================================== *)
(** Access paths and expressions *)

let variable_of_varinfo = Memo.memo (fun vi ->
  if vi.Cil.vglob then Varinfo.mk_global vi.Cil.vname (type_of_var vi)
  else Varinfo.mk_local vi.Cil.vname (type_of_var vi))

let rec tr_expr = function
  | Cil.Const c -> Constant (tr_constant c)
  | Cil.Lval ((Cil.Var v, Cil.NoOffset) as l)
      when Cil.isFunctionType v.Cil.vtype ->
      addr_of (tr_lval l)
  | Cil.Lval l -> AccessPath (tr_lval l)
  | Cil.SizeOf t -> tr_expr (Cil.constFold true (Cil.SizeOf t))
  | Cil.SizeOfE e -> tr_expr (Cil.constFold true (Cil.SizeOfE e))
  | Cil.SizeOfStr s -> tr_expr (Cil.constFold true (Cil.SizeOfStr s))
  | Cil.AlignOf t -> assert false
  | Cil.AlignOfE e -> assert false
  | Cil.UnOp (op, expr, typ) ->
      let expr = tr_expr expr in
      let typ = tr_typ typ in
        (match op with
           | Cil.Neg -> UnaryOp (Neg, expr, typ)
           | Cil.BNot -> UnaryOp (BNot, expr, typ)
           | Cil.LNot -> BoolExpr (Bexpr.negate (Bexpr.of_expr expr)))
  | Cil.BinOp (op, e1, e2, typ) ->
      let e1 = tr_expr e1 in
      let e2 = tr_expr e2 in
      let typ = tr_typ typ in
        (match op with
           | Cil.PlusA -> BinaryOp (e1, Add, e2, typ)
           | Cil.MinusA -> BinaryOp (e1, Minus, e2, typ)
           | Cil.Mult -> BinaryOp (e1, Mult, e2, typ)
           | Cil.Div -> BinaryOp (e1, Div, e2, typ)
           | Cil.Mod -> BinaryOp (e1, Mod, e2, typ)
           | Cil.Shiftlt -> BinaryOp (e1, ShiftL, e2, typ)
           | Cil.Shiftrt -> BinaryOp (e1, ShiftR, e2, typ)
           | Cil.BAnd -> BinaryOp (e1, BAnd, e2, typ)
           | Cil.BOr -> BinaryOp (e1, BOr, e2, typ)
           | Cil.BXor -> BinaryOp (e1, BXor, e2, typ)
           | Cil.Lt -> BoolExpr (Atom (Lt, e1, e2))
           | Cil.Gt -> BoolExpr (Bexpr.gt e1 e2)
           | Cil.Le -> BoolExpr (Atom (Le, e1, e2))
           | Cil.Ge -> BoolExpr (Bexpr.ge e1 e2)
           | Cil.Eq -> BoolExpr (Atom (Eq, e1, e2))
           | Cil.Ne -> BoolExpr (Atom (Ne, e1, e2))
           | Cil.LAnd -> BoolExpr (And (Bexpr.of_expr e1, Bexpr.of_expr e2))
           | Cil.LOr -> BoolExpr (Or (Bexpr.of_expr e1, Bexpr.of_expr e2))
           | Cil.IndexPI | Cil.PlusPI -> (* these are equivalent *)
	       BinaryOp (e1, Add, e2, typ)
           | Cil.MinusPI | Cil.MinusPP -> (* these are equivalent *)
	       BinaryOp (e1, Minus, e2, typ))
  | Cil.CastE (t, e) -> Cast (tr_typ t, tr_expr e)
  | Cil.AddrOf l -> addr_of (tr_lval l)
  | Cil.StartOf l ->
      (* Conversion of an array type to a pointer type *)
      addr_of (tr_lval l)
  | Cil.Question (test, left, right, typ) -> assert false

and tr_constant = function
  | Cil.CInt64 (i, ik, _) -> CInt (Int64.to_int i, ik_of_ikind ik)
  | Cil.CStr s -> CString s
  | Cil.CWStr i -> assert false
  | Cil.CChr c -> CChar c
  | Cil.CReal (f, fk, _) -> CFloat (f, fk_of_fkind fk)
  | Cil.CEnum (e, s, ei) -> assert false

(** Converts a Cil lval to an access path. *)
and tr_lval lval =
  let rec do_offset ap = function
    | Cil.NoOffset -> ap
    | Cil.Field (fi, next) ->
	do_offset (AP.offset ap (OffsetFixed (field_offset fi))) next
    | Cil.Index (i, next) ->
      try
	let offset = OffsetFixed (calc_expr i) in
	do_offset (AP.offset ap offset) next
      with Not_constant _ ->
	do_offset (Deref (Expr.add (addr_of ap) (tr_expr i))) next
  in
  let base = match fst lval with
    | Cil.Var vi -> Variable (Var.mk (variable_of_varinfo vi))
    | Cil.Mem expr -> Deref (tr_expr expr)
  in
    do_offset base (snd lval)

(* ========================================================================== *)
(** Definitions *)

(* Translation context *)
type ctx =
  { ctx_func : CfgIr.func;
    ctx_labelled : (int, Def.t) Hashtbl.t;
    mutable ctx_goto : (Def.t * int) list }
let ctx_cfg ctx = ctx.ctx_func.CfgIr.cfg

let tr_instr ctx instr =
  let open CfgIr.CfgBuilder in
  let mk_single = mk_single (ctx_cfg ctx) in
  let mk_seq = mk_seq (ctx_cfg ctx) in
  match instr with
  | Cil.Set (l, e, loc) ->
    let rhs = tr_expr e in
    begin match tr_lval l with
    | Variable v -> mk_single (Def.mk ~loc:loc (Assign (v, rhs)))
    | ap -> mk_single (Def.mk ~loc:loc (Store (ap, rhs)))
    end
  | Cil.Call (lhs, Cil.Lval (Cil.Var v, Cil.NoOffset), args, loc) ->
    let lhs = match lhs with
      | Some l -> Some (tr_lval l)
      | None   -> None
    in
    let mk_def kind = mk_single (Def.mk ~loc:loc kind) in
    begin match v.Cil.vname, lhs, List.map tr_expr args with
    | ("assume", None, [x]) -> mk_def (Assume (Bexpr.of_expr x))
    | ("assert", None, [x]) -> begin
      (* Pretty print the cil expression for the error message - it should
	 be closer the source text than the translation *)
      match args with
      | [cil_arg] ->
	let error_msg = Pretty.sprint ~width:80 (Cil.d_exp () cil_arg) in
	mk_def (Assert (Bexpr.of_expr x, error_msg))
      | _ -> assert false
    end
    | ("__assert_fail", None, [_;_;_;_]) ->
      mk_def (Assert (Bexpr.kfalse, "fail"))
    | ("malloc", Some (Variable v), [x]) ->
      mk_def (Builtin (Alloc (v, x, AllocHeap)))
    | ("calloc", Some (Variable v), [mem;size]) ->
      mk_def (Builtin (Alloc (v,
			      BinaryOp (mem, Mult, size, Concrete (Int IInt)),
			      AllocHeap)))
    | ("realloc", Some (Variable v), [_;x]) ->
      mk_def (Builtin (Alloc (v, x, AllocHeap)))
    (* glibc #defines alloca to be __builtin_alloca *)
    | ("__builtin_alloca", Some (Variable v), [x]) ->
      mk_def (Builtin (Alloc (v, x, AllocStack)))
    | ("pthread_mutex_lock", None, [x]) -> mk_def (Builtin (Acquire x))
    | ("pthread_mutex_unlock", None, [x]) -> mk_def (Builtin (Release x))
    | ("spin_lock", None, [x]) -> mk_def (Builtin (Acquire x))
    | ("spin_unlock", None, [x]) -> mk_def (Builtin (Release x))
    | ("pthread_create", Some (Variable v), [_;_;func;arg]) ->
      mk_def (Builtin (Fork (Some v, func, [arg])))
    | ("pthread_create", None, [_;_;func;arg]) ->
      mk_def (Builtin (Fork (None, func, [arg])))
    | ("exit", _, [_]) -> mk_def (Builtin Exit)

    | ("rand", Some (Variable v), []) ->
      (* todo: should be non-negative *)
      mk_def (Assign (v, Havoc (Concrete (Int IInt))))

    (* CPROVER builtins *)
    | ("__CPROVER_atomic_begin", None, []) -> mk_def (Builtin AtomicBegin)
    | ("__CPROVER_atomic_end", None, []) -> mk_def (Builtin AtomicEnd)

    | (_, Some (Variable lhs), args) ->
      mk_def (Call (Some lhs,
		    tr_expr (Cil.Lval (Cil.Var v, Cil.NoOffset)),
		    args))
    | (_, None, args) ->
      mk_def (Call (None,
		    tr_expr (Cil.Lval (Cil.Var v, Cil.NoOffset)),
		    args))
    | (_, Some (Deref expr), args) ->
      let tmp = CfgIr.mk_local_var ctx.ctx_func "__tmp" (Expr.get_type expr) in
      let call =
	mk_def (Call (Some tmp,
		      tr_expr (Cil.Lval (Cil.Var v, Cil.NoOffset)),
		      args))
      in
      let store = mk_def (Store (Deref expr, AccessPath (Variable tmp))) in
      mk_seq call store
    end
  | Cil.Call (lhs, func, args, loc) ->
    let lhs = match lhs with
      | Some l -> Some (tr_lval l)
      | None   -> None
    in
    let func = tr_expr func in
    let args = List.map tr_expr args in
    begin match lhs with
    | Some (Variable v) ->
      mk_single (Def.mk ~loc:loc (Call (Some v, func, args)))
    | None -> mk_single (Def.mk ~loc:loc (Call (None, func, args)))
    | Some (Deref expr) ->
      let tmp = CfgIr.mk_local_var ctx.ctx_func "__tmp" (Expr.get_type expr) in
      let call = mk_single (Def.mk ~loc:loc (Call (Some tmp, func, args))) in
      let store =
	mk_single
	  (Def.mk ~loc:loc (Store (Deref expr, AccessPath (Variable tmp))))
      in
      mk_seq call store
    end
  | Cil.Asm (_, _, _, _, _, loc) ->
    (* TODO - this is unsound *)
    mk_single (Def.mk ~loc:loc (Assume Bexpr.ktrue))

(* ========================================================================== *)
(** Statements *)

let rec tr_stmtkind ctx stmt =
  let open CfgIr.CfgBuilder in
  let cfg = ctx_cfg ctx in
  match stmt with
  | Cil.Instr instrs -> mk_block cfg (List.map (tr_instr ctx) instrs)
  | Cil.Return (Some re, loc) ->
    mk_single cfg (Def.mk ~loc:loc (Return (Some (tr_expr re))))
  | Cil.Return (None, loc) -> mk_single cfg (Def.mk ~loc:loc (Return None))
  | Cil.Goto (stmtref, _) ->
    let ventry = fst (mk_skip cfg) in
    let vexit = fst (mk_skip cfg) in
    ctx.ctx_goto <- (ventry, (!stmtref).Cil.sid)::ctx.ctx_goto;
    (ventry, vexit)
  | Cil.Block b -> mk_block cfg (List.map (tr_stmt ctx) b.Cil.bstmts)
  | Cil.If (cond, bthen, belse, _) ->
    mk_if
      cfg
      (Bexpr.of_expr (tr_expr cond))
      (mk_block cfg (List.map (tr_stmt ctx) bthen.Cil.bstmts))
      (mk_block cfg (List.map (tr_stmt ctx) belse.Cil.bstmts))
  | _ -> assert false
and tr_stmt ctx stmt =
  let ivl = tr_stmtkind ctx stmt.Cil.skind in
  if not (BatList.is_empty stmt.Cil.labels)
  then Hashtbl.add ctx.ctx_labelled stmt.Cil.sid (fst ivl);
  ivl

(* ========================================================================== *)
(** File *)

let tr_func f =
  let cfg = CfgIr.Cfg.create () in
  let func_ir =
    { CfgIr.fname = variable_of_varinfo f.Cil.svar;
      CfgIr.formals = List.map variable_of_varinfo f.Cil.sformals;
      CfgIr.locals = List.map variable_of_varinfo f.Cil.slocals;
      CfgIr.cfg = cfg;
      CfgIr.file = None }
  in
  let ctx =
    { ctx_func = func_ir;
      ctx_labelled = Hashtbl.create 97;
      ctx_goto = [] }
  in
  let add_goto (v, target) =
    try CfgIr.Cfg.add_edge cfg v (Hashtbl.find ctx.ctx_labelled target)
    with Not_found -> begin
      Log.logf Log.top "Missing label (CIL frontend)";
      assert false
    end
  in
  let body =
    CfgIr.CfgBuilder.mk_block
      cfg
      (List.map (tr_stmt ctx) f.Cil.sbody.Cil.bstmts)
  in
  let init = CfgIr.CfgBuilder.mk_skip cfg in
  List.iter add_goto ctx.ctx_goto;
  ignore (CfgIr.CfgBuilder.mk_seq cfg init body);
  CfgIr.normalize_cfg cfg;
  CfgIr.remove_unreachable cfg (fst init);
  func_ir

let rec tr_file_vars = function
  | (x::xs) -> let rest = tr_file_vars xs in
      (match x with
	 | Cil.GVarDecl (v, _) -> (variable_of_varinfo v)::rest
	 | Cil.GVar (v, _, _) -> (variable_of_varinfo v)::rest
	 | _ -> rest)
  | [] -> []

(* Provide definitions for argc/argv *)
let define_args file =
  let open CfgIr in
  let main = match file.entry_points with
    | [x] -> x
    | _   -> failwith ("CfgIr.define_args: " ^
			 "no support for multiple entry points")
  in
  let main_func = lookup_function main file in
  let init_vertex = Cfg.initial_vertex main_func.cfg in
  let (argc, argv) = match main_func.formals with
    | [argc;argv] -> (argc,argv)
    | [] -> begin
	let argc = Varinfo.mk_local "argc" (Concrete (Int IInt)) in
	let string = Concrete (Pointer (Concrete (Int IChar))) in
	let argv = Varinfo.mk_local "argv" (Concrete (Pointer string)) in
	  main_func.formals <- [argc;argv];
	  (argc,argv)
      end
    | _ -> failwith ("CfgIr.define_args: wrong # of params to main")
  in
  let define0 =
    Def.mk (Assume (Bexpr.ge
		      (AccessPath (Variable (Var.mk argc)))
		      Expr.zero))
  in
  let define1 =
    Def.mk (Builtin (Alloc (Var.mk argv,
			    AccessPath (Variable (Var.mk argc)),
			    AllocStack)))
  in
    insert_pre define0 init_vertex main_func.cfg;
    insert_pre define1 init_vertex main_func.cfg

let tr_file_funcs =
  let rec go = function
    | (Cil.GFun (f,_)::rest) -> (tr_func f)::(go rest)
    | (_::rest) -> go rest
    | [] -> []
  in
    go

let tr_file filename f =
  let open CfgIr in
  let file = {
    filename = filename;
    vars = tr_file_vars f.Cil.globals;
    funcs = tr_file_funcs f.Cil.globals;
    types = HT.fold (fun _ typ rest -> typ::rest) named_hash [];
    entry_points = [];
    threads = [];
    globinit = None
  }
  in
  List.iter (fun f -> f.file <- Some file) file.funcs;

  (* todo: merge globinit with init, if it exists *)
  let is_init f = (Varinfo.show f.fname) = "init" in
  let (init, funcs) = match List.partition is_init file.funcs with
    | ([init], funcs) -> (Some init, funcs)
    | _               -> (None, file.funcs)
  in
  file.funcs <- funcs;
  file.globinit <- init;
  if !whole_program
  then file.entry_points <- [(lookup_function_name "main" file).fname]
  else file.entry_points <- List.map (fun f -> f.fname) file.funcs;
  file.threads <- file.entry_points;
  file

let parse filename =
  let base = Filename.chop_extension (Filename.basename filename) in
  let go preprocessed =
    (* "preprocessed" is a fresh name where we can store the preprocessed
       file *)
    let library_path =
      if !CmdLine.library_path = "" then ""
      else begin
	Log.logf Log.info "Using library: %s" !CmdLine.library_path;
	" -I" ^ !CmdLine.library_path
      end
    in
    let pp_cmd =
      Printf.sprintf "gcc %s-E %s -o %s" library_path filename preprocessed
    in
    ignore (Sys.command pp_cmd);
    let file = Frontc.parse preprocessed () in
    simplify file;
    tr_file filename file
  in
  Putil.with_temp_filename base ".i" go

let _ = CmdLine.register_parser ("c", parse)
