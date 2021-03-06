open BatPervasives
open BatHashcons

type typ_fo = [ `TyInt | `TyReal | `TyBool ] [@@ deriving ord]

type typ = [
  | `TyInt
  | `TyReal
  | `TyBool
  | `TyFun of (typ_fo list * typ_fo)
] [@@ deriving ord]

type typ_arith = [ `TyInt | `TyReal ] [@@ deriving ord]
type typ_bool = [ `TyBool ]
type 'a typ_fun = [ `TyFun of (typ_fo list) * 'a ]

type symbol = int
  [@@deriving ord]

let pp_typ_fo formatter = function
  | `TyReal -> Format.pp_print_string formatter "real"
  | `TyInt -> Format.pp_print_string formatter "int"
  | `TyBool -> Format.pp_print_string formatter "bool"

let pp_typ formatter = function
  | `TyInt -> pp_typ_fo formatter `TyInt
  | `TyReal -> pp_typ_fo formatter `TyReal
  | `TyBool -> pp_typ_fo formatter `TyBool
  | `TyFun (dom, cod) ->
    let pp_sep formatter () = Format.fprintf formatter "@ * " in
    Format.fprintf formatter "(@[%a@ -> %a@])"
      (ArkUtil.pp_print_enum ~pp_sep pp_typ_fo) (BatList.enum dom)
      pp_typ_fo cod

let pp_typ_arith = pp_typ
let pp_typ_fo = pp_typ

let subtype s t = s = t || (s = `TyInt && t = `TyReal)

type label =
  | True
  | False
  | And
  | Or
  | Not
  | Exists of string * typ_fo
  | Forall of string * typ_fo
  | Eq
  | Leq
  | Lt
  | App of symbol
  | Var of int * typ_fo
  | Add
  | Mul
  | Div
  | Mod
  | Floor
  | Neg
  | Real of QQ.t
  | Ite

type sexpr = Node of label * ((sexpr hobj) list) * typ_fo
type ('a,'typ) expr = sexpr hobj
type 'a term = ('a, typ_arith) expr
type 'a formula = ('a, typ_bool) expr

let compare_expr s t = Pervasives.compare s.tag t.tag
let compare_formula = compare_expr
let compare_term = compare_expr

module HC = BatHashcons.MakeTable(struct
    type t = sexpr
    let equal (Node (label, args, typ)) (Node (label', args', typ')) =
      (match label, label' with
       | Exists (_, typ), Exists (_, typ') -> typ = typ'
       | Forall (_, typ), Forall (_, typ') -> typ = typ'
       | _, _ -> label = label')
      && typ == typ'
      && List.length args == List.length args'
      && List.for_all2 (fun x y -> x.tag = y.tag) args args'
    let compare = Pervasives.compare
    let hash (Node (label, args, _)) =
      Hashtbl.hash (label, List.map (fun sexpr -> sexpr.tag) args)
  end)

module DynArray = BatDynArray

module Symbol = struct
  type t = symbol
  let compare = Pervasives.compare
  module Set = ArkUtil.Int.Set
  module Map = ArkUtil.Int.Map
end

module Var = struct
  module I = struct
    type t = int * typ_fo [@@deriving show,ord]
  end
  include I
  module Set = BatSet.Make(I)
  module Map = BatMap.Make(I)
end

module Env = struct
  type 'a t = 'a list
  let push x xs = x::xs
  let find xs i =
    try List.nth xs i
    with Failure _ -> raise Not_found
  let empty = []
  let enum = BatList.enum
end

let rec eval_sexpr alg sexpr =
  let (Node (label, children, typ)) = sexpr.obj in
  alg label (List.map (eval_sexpr alg) children) typ

let rec flatten_sexpr label sexpr =
  let Node (label', children, _) = sexpr.obj in
  if label = label' then
    List.concat (List.map (flatten_sexpr label) children)
  else
    [sexpr]

type ('a, 'b) open_term = [
  | `Real of QQ.t
  | `App of symbol * (('b, typ_fo) expr list)
  | `Var of int * typ_arith
  | `Add of 'a list
  | `Mul of 'a list
  | `Binop of [ `Div | `Mod ] * 'a * 'a
  | `Unop of [ `Floor | `Neg ] * 'a
  | `Ite of ('b formula) * 'a * 'a
]

type ('a,'b) open_formula = [
  | `Tru
  | `Fls
  | `And of 'a list
  | `Or of 'a list
  | `Not of 'a
  | `Quantify of [`Exists | `Forall] * string * typ_fo * 'a
  | `Atom of [`Eq | `Leq | `Lt] * 'b term * 'b term
  | `Ite of 'a * 'a * 'a
  | `Proposition of [ `Var of int
                    | `App of symbol * ('b, typ_fo) expr list ]
]

exception Quit

class type ['a] smt_model = object
  method eval_int : 'a term -> ZZ.t
  method eval_real : 'a term -> QQ.t
  method eval_fun : symbol -> ('a, typ_fo) expr
  method sat :  'a formula -> bool
  method to_string : unit -> string
end

class type ['a] smt_solver = object
  method add : ('a formula) list -> unit
  method push : unit -> unit
  method pop : int -> unit
  method reset : unit -> unit
  method check : ('a formula) list -> [ `Sat | `Unsat | `Unknown ]
  method to_string : unit -> string
  method get_model : unit -> [ `Sat of 'a smt_model | `Unsat | `Unknown ]
  method get_unsat_core : ('a formula) list ->
    [ `Sat | `Unsat of ('a formula) list | `Unknown ]
end

type 'a context =
  { hashcons : HC.t;
    symbols : (string * typ) DynArray.t;
    named_symbols : (string,int) Hashtbl.t;
    mk : label -> (sexpr hobj) list -> sexpr hobj;
  }

let size expr =
  let open ArkUtil.Int in
  let counted = ref Set.empty in
  let rec go sexpr =
    let (Node (_, children, _)) = sexpr.obj in
    if Set.mem sexpr.tag (!counted) then
      1
    else begin
      counted := Set.add sexpr.tag (!counted);
      List.fold_left (fun sz child -> sz + (go child)) 1 children
    end
  in
  go expr

let mk_symbol ctx ?(name="K") typ =
  DynArray.add ctx.symbols (name, typ);
  DynArray.length ctx.symbols - 1

let register_named_symbol ctx name typ =
  if Hashtbl.mem ctx.named_symbols name then
    invalid_arg ("register_named_symbol: The name `"
                 ^ name
                 ^ "' has already been registered")
  else
    Hashtbl.add ctx.named_symbols name (mk_symbol ctx ~name typ)

let get_named_symbol ctx name = Hashtbl.find ctx.named_symbols name

let is_registered_name ctx name = Hashtbl.mem ctx.named_symbols name

let symbol_name ctx sym =
  let name = fst (DynArray.get ctx.symbols sym) in
  if is_registered_name ctx name then Some name
  else None

let typ_symbol ctx = snd % DynArray.get ctx.symbols
let pp_symbol ctx formatter symbol =
  Format.fprintf formatter "%s:%d"
    (fst (DynArray.get ctx.symbols symbol))
    symbol

let show_symbol ctx symbol = fst (DynArray.get ctx.symbols symbol)
let symbol_of_int x = x
let int_of_symbol x = x

let mk_real ctx qq = ctx.mk (Real qq) []
let mk_zero ctx = mk_real ctx QQ.zero
let mk_one ctx = mk_real ctx QQ.one

let mk_const ctx k = ctx.mk (App k) []
let mk_app ctx symbol actuals = ctx.mk (App symbol) actuals
let mk_var ctx v typ = ctx.mk (Var (v, typ)) []

let mk_neg ctx t = ctx.mk Neg [t]
let mk_div ctx s t = ctx.mk Div [s; t]
let mk_mod ctx s t = ctx.mk Mod [s; t]
let mk_floor ctx t = ctx.mk Floor [t]
let mk_ceiling ctx t = mk_neg ctx (mk_floor ctx (mk_neg ctx t))

let mk_add ctx = function
  | [] -> mk_zero ctx
  | [x] -> x
  | sum -> ctx.mk Add sum

let mk_mul ctx = function
  | [] -> mk_one ctx
  | [x] -> x
  | product -> ctx.mk Mul product

let mk_sub ctx s t = mk_add ctx [s; mk_neg ctx t]

let rec mk_pow ctx t n =
  if n = 0 then mk_one ctx
  else if n = 1 then t
  else if n < 0 then mk_div ctx (mk_one ctx) (mk_pow ctx t (-n))
  else
    let q = mk_pow ctx t (n / 2) in
    let q_squared = mk_mul ctx [q; q] in
    if n mod 2 = 0 then q_squared
    else mk_mul ctx [q; q_squared]

let mk_true ctx = ctx.mk True []
let mk_false ctx = ctx.mk False []
let mk_leq ctx s t = ctx.mk Leq [s; t]
let mk_lt ctx s t = ctx.mk Lt [s; t]
let mk_eq ctx s t = ctx.mk Eq [s; t]

let is_true phi = match phi.obj with
  | Node (True, [], _) -> true
  | _ -> false

let is_false phi = match phi.obj with
  | Node (False, [], _) -> true
  | _ -> false

let is_zero phi = match phi.obj with
  | Node (Real k, [], _) -> QQ.equal k QQ.zero
  | _ -> false

let is_one phi = match phi.obj with
  | Node (Real k, [], _) -> QQ.equal k QQ.one
  | _ -> false

let mk_not ctx phi = ctx.mk Not [phi]
let mk_and ctx conjuncts = ctx.mk And conjuncts
let mk_or ctx disjuncts = ctx.mk Or disjuncts
let mk_forall ctx ?name:(name="_") typ phi = ctx.mk (Forall (name, typ)) [phi]
let mk_exists ctx ?name:(name="_") typ phi = ctx.mk (Exists (name, typ)) [phi]

let mk_iff ctx phi psi =
  mk_or ctx [mk_and ctx [phi; psi];
             mk_and ctx [mk_not ctx phi; mk_not ctx psi]]

let mk_implies ctx phi psi = mk_or ctx [mk_not ctx phi; psi]

let mk_ite ctx cond bthen belse = ctx.mk Ite [cond; bthen; belse]
let mk_iff ctx phi psi =
  mk_or ctx [mk_and ctx [phi; psi]; mk_and ctx [mk_not ctx phi; mk_not ctx psi]]
let mk_if ctx phi psi = mk_or ctx [mk_not ctx phi; psi]

let mk_truncate ctx t =
  mk_ite ctx
    (mk_leq ctx (mk_zero ctx) t)
    (mk_floor ctx t)
    (mk_ceiling ctx t)

(* Equivalent to mk_truncate ctx (mk_div ctx s t), but with built-in sign
   analysis *)
let mk_idiv ctx s t =
  let zero = mk_zero ctx in
  let div = mk_div ctx s t in
  let s_pos = mk_leq ctx zero s in
  let t_pos = mk_leq ctx zero t in
  mk_ite ctx
    (mk_iff ctx s_pos t_pos)
    (mk_floor ctx div)
    (mk_ceiling ctx div)

(* Avoid capture by incrementing bound variables *)
let rec decapture ctx depth incr sexpr =
  let Node (label, children, _) = sexpr.obj in
  match label with
  | Exists (_, _) | Forall (_, _) ->
    decapture_children ctx label (depth + 1) incr children
  | Var (v, typ) ->
    if v < depth then
      (* v is bound *)
      sexpr
    else
      ctx.mk (Var (v + incr, typ)) []
  | _ -> decapture_children ctx label depth incr children
and decapture_children ctx label depth incr children =
  ctx.mk label (List.map (decapture ctx depth incr) children)

let substitute ctx subst sexpr =
  let rec go depth sexpr =
    let Node (label, children, _) = sexpr.obj in
    match label with
    | Exists (_, _) | Forall (_, _) ->
      go_children label (depth + 1) children
    | Var (v, _) ->
      if v < depth then (* bound var *)
        sexpr
      else
        decapture ctx 0 depth (subst (v - depth))
    | _ -> go_children label depth children
  and go_children label depth children =
    ctx.mk label (List.map (go depth) children)
  in
  go 0 sexpr

let substitute_const ctx subst sexpr =
  let rec go depth sexpr =
    let Node (label, children, _) = sexpr.obj in
    match label with
    | Exists (_, _) | Forall (_, _) ->
      go_children label (depth + 1) children
    | App k when children = [] -> decapture ctx 0 depth (subst k)
    | _ -> go_children label depth children
  and go_children label depth children =
    ctx.mk label (List.map (go depth) children)
  in
  go 0 sexpr

let substitute_map ctx map sexpr =
  let subst sym =
    if Symbol.Map.mem sym map then
      Symbol.Map.find sym map
    else
      mk_const ctx sym
  in
  substitute_const ctx subst sexpr

let fold_constants f sexpr acc =
  let rec go acc sexpr =
    let Node (label, children, _) = sexpr.obj in
    match label with
    | App k -> List.fold_left go (f k acc) children
    | _ -> List.fold_left go acc children
  in
  go acc sexpr

let symbols sexpr = fold_constants Symbol.Set.add sexpr Symbol.Set.empty

let vars sexpr =
  let rec go depth sexpr =
    let Node (label, children, _) = sexpr.obj in
    match label with
    | Exists (_, _) | Forall (_, _) ->
      go_children (depth + 1) children
    | Var (v, typ) ->
      if v < depth then Var.Set.empty
      else Var.Set.singleton (v - depth, typ)
    | _ -> go_children depth children
  and go_children depth children =
    List.fold_left
      Var.Set.union
      Var.Set.empty
      (List.map (go depth) children)
  in
  go 0 sexpr

let free_vars sexpr =
  let table = BatHashtbl.create 991 in
  let add_var v typ =
    if BatHashtbl.mem table v then
      (if not (BatHashtbl.find table v = typ) then
         invalid_arg "free_vars: ill-formed expression")
    else
      BatHashtbl.add table v typ
  in
  let rec go depth sexpr =
    let Node (label, children, _) = sexpr.obj in
    match label with
    | Exists (_, _) | Forall (_, _) ->
      List.iter (go (depth + 1)) children
    | Var (v, typ) when v >= depth ->
      add_var (v - depth) typ
    | _ -> List.iter (go depth) children
  in
  go 0 sexpr;
  table

let destruct ctx sexpr =
  match sexpr.obj with
  | Node (Real qq, [], _) -> `Real qq
  | Node (App func, args, _) -> `App (func, args)
  | Node (Var (v, `TyReal), [], _) -> `Var (v, `TyReal)
  | Node (Var (v, `TyInt), [], _) -> `Var (v, `TyInt)
  | Node (Var (v, `TyBool), [], _) -> `Proposition (`Var v)
  | Node (Add, sum, _) -> `Add sum
  | Node (Mul, product, _) -> `Mul product
  | Node (Div, [s; t], _) -> `Binop (`Div, s, t)
  | Node (Mod, [s; t], _) -> `Binop (`Mod, s, t)
  | Node (Floor, [t], _) -> `Unop (`Floor, t)
  | Node (Neg, [t], _) -> `Unop (`Neg, t)
  | Node (Ite, [cond; bthen; belse], _) -> `Ite (cond, bthen, belse)
  | Node (True, [], _) -> `Tru
  | Node (False, [], _) -> `Fls
  | Node (And, conjuncts, _) -> `And conjuncts
  | Node (Or, disjuncts, _) -> `Or disjuncts
  | Node (Not, [phi], _) -> `Not phi
  | Node (Exists (name, typ), [phi], _) -> `Quantify (`Exists, name, typ, phi)
  | Node (Forall (name, typ), [phi], _) -> `Quantify (`Forall, name, typ, phi)
  | Node (Eq, [s; t], _) -> `Atom (`Eq, s, t)
  | Node (Leq, [s; t], _) -> `Atom (`Leq, s, t)
  | Node (Lt, [s; t], _) -> `Atom (`Lt, s, t)
  | Node (_, _, _) -> assert false

let rec flatten_universal phi = match phi.obj with
  | Node (Forall (name, typ), [phi], _) ->
    let (varinfo, phi') = flatten_universal phi in
    ((name,typ)::varinfo, phi')
  | _ -> ([], phi)

let rec flatten_existential phi = match phi.obj with
  | Node (Exists (name, typ), [phi], _) ->
    let (varinfo, phi') = flatten_existential phi in
    ((name,typ)::varinfo, phi')
  | _ -> ([], phi)

let rec pp_expr ?(env=Env.empty) ctx formatter expr =
  let Node (label, children, _) = expr.obj in
  let open Format in
  match label, children with
  | Real qq, [] -> QQ.pp formatter qq
  | App k, [] -> pp_symbol ctx formatter k
  | App func, args ->
    fprintf formatter "%a(@[%a@])"
      (pp_symbol ctx) func
      (ArkUtil.pp_print_enum_nobox (pp_expr ~env ctx)) (BatList.enum args)
  | Var (v, typ), [] ->
    (try fprintf formatter "[%s:%d]" (Env.find env v) v
     with Not_found -> fprintf formatter "[free:%d]" v)
  | Add, terms ->
    fprintf formatter "(@[";
    ArkUtil.pp_print_enum
      ~pp_sep:(fun formatter () -> fprintf formatter "@ + ")
      (pp_expr ~env ctx)
      formatter
      (BatList.enum terms);
    fprintf formatter "@])"
  | Mul, terms ->
    fprintf formatter "(@[";
    ArkUtil.pp_print_enum
      ~pp_sep:(fun formatter () -> fprintf formatter "@ * ")
      (pp_expr ~env ctx)
      formatter
      (BatList.enum terms);
    fprintf formatter "@])"
  | Div, [s; t] ->
    fprintf formatter "(@[%a@ / %a@])"
      (pp_expr ~env ctx) s
      (pp_expr ~env ctx) t
  | Mod, [s; t] ->
    fprintf formatter "(@[%a@ mod %a@])"
      (pp_expr ~env ctx) s
      (pp_expr ~env ctx) t
  | Floor, [t] ->
    fprintf formatter "floor(@[%a@])" (pp_expr ~env ctx) t
  | Neg, [{obj = Node (Real qq, [], _)}] ->
    QQ.pp formatter (QQ.negate qq)
  | Neg, [{obj = Node (App _, _, _)} as t]
  | Neg, [{obj = Node (Var (_, _), [], _)} as t] ->
    fprintf formatter "-%a" (pp_expr ~env ctx) t
  | Neg, [t] -> fprintf formatter "-(@[%a@])" (pp_expr ~env ctx) t
  | True, [] -> pp_print_string formatter "true"
  | False, [] -> pp_print_string formatter "false"
  | Not, [phi] ->
    fprintf formatter "!(@[%a@])" (pp_expr ~env ctx) phi
  | And, conjuncts ->
    fprintf formatter "(@[";
    ArkUtil.pp_print_enum
      ~pp_sep:(fun formatter () -> fprintf formatter "@ /\\ ")
      (pp_expr ~env ctx)
      formatter
      (BatList.enum (List.concat (List.map (flatten_sexpr And) conjuncts)));
    fprintf formatter "@])"
  | Or, disjuncts ->
    fprintf formatter "(@[";
    ArkUtil.pp_print_enum
      ~pp_sep:(fun formatter () -> fprintf formatter "@ \\/ ")
      (pp_expr ~env ctx)
      formatter
      (BatList.enum (List.concat (List.map (flatten_sexpr Or) disjuncts)));
    fprintf formatter "@])"
  | Eq, [x; y] ->
    fprintf formatter "@[%a = %a@]"
      (pp_expr ~env ctx) x
      (pp_expr ~env ctx) y
  | Leq, [x; y] ->
    fprintf formatter "@[%a <= %a@]"
      (pp_expr ~env ctx) x
      (pp_expr ~env ctx) y
  | Lt, [x; y] ->
    fprintf formatter "@[%a < %a@]"
      (pp_expr ~env ctx) x
      (pp_expr ~env ctx) y
  | Exists (name, typ), [psi] | Forall (name, typ), [psi] ->
      let (quantifier_name, varinfo, psi) =
        match label with
        | Exists (_, _) ->
          let (varinfo, psi) = flatten_existential psi in
          ("exists", (name, typ)::varinfo, psi)
        | Forall (_, _) ->
          let (varinfo, psi) = flatten_universal psi in
          ("forall", (name, typ)::varinfo, psi)
        | _ -> assert false
      in
      let env =
        List.fold_left (fun env (x,_) -> Env.push x env) env varinfo
      in
      fprintf formatter "(@[%s@ " quantifier_name;
      ArkUtil.pp_print_enum
        ~pp_sep:pp_print_space
        (fun formatter (name, typ) ->
           fprintf formatter "(%s : %a)" name pp_typ typ)
        formatter
        (BatList.enum varinfo);
      fprintf formatter ".@ %a@])" (pp_expr ~env ctx) psi
  | Ite, [cond; bthen; belse] ->
    fprintf formatter "ite(@[%a,@ %a,@ %a@])"
      (pp_expr ~env ctx) cond
      (pp_expr ~env ctx) bthen
      (pp_expr ~env ctx) belse
  | _ -> failwith "pp_expr: ill-formed expression"

module Expr = struct
  module Inner = struct
    type t = sexpr hobj
    let equal s t = s.tag = t.tag
    let compare s t = Pervasives.compare s.tag t.tag
    let hash t = t.hcode
  end
  include Inner

  let refine ctx sexpr =
    match sexpr.obj with
    | Node (_, _, `TyInt) -> `Term sexpr
    | Node (_, _, `TyReal) -> `Term sexpr
    | Node (_, _, `TyBool) -> `Formula sexpr

  let pp = pp_expr

  module HT = struct
    module HT = BatHashtbl.Make(Inner)
    type ('a, 'typ, 'b) t = 'b HT.t
    let create = HT.create
    let add = HT.add
    let replace = HT.replace
    let remove = HT.remove
    let find = HT.find
    let mem = HT.mem
    let keys = HT.keys
    let values = HT.values
    let enum = HT.enum
  end

  module Set = struct
    module S = BatSet.Make(Inner)
    type ('a, 'typ) t = S.t
    let empty = S.empty
    let add = S.add
    let union = S.union
    let inter = S.inter
    let enum = S.enum
    let mem = S.mem
  end

  module Map = struct
    module M = BatMap.Make(Inner)
    type ('a, 'typ, 'b) t = 'b M.t
    let empty = M.empty
    let is_empty = M.is_empty
    let add = M.add
    let map = M.map
    let filter = M.filter
    let filter_map = M.filter_map
    let remove = M.remove
    let find = M.find
    let keys = M.keys
    let values = M.values
    let enum = M.enum
    let merge = M.merge
    let fold = M.fold
  end
end

module Term = struct
  type 'a t = 'a term
  let equal s t = s.tag = t.tag
  let compare s t = Pervasives.compare s.tag t.tag
  let hash t = t.hcode

  let eval ctx alg t =
    let rec go t =
      match t.obj with
      | Node (Real qq, [], _) -> alg (`Real qq)
      | Node (App func, args, `TyBool) -> invalid_arg "eval: not a term"
      | Node (App func, args, `TyInt) | Node (App func, args, `TyReal) ->
        alg (`App (func, args))
      | Node (Var (v, typ), [], _) ->
        begin match typ with
          | `TyInt -> alg (`Var (v, `TyInt))
          | `TyReal -> alg (`Var (v, `TyReal))
          | `TyBool -> invalid_arg "eval: not a term"
        end
      | Node (Add, sum, _) -> alg (`Add (List.map go sum))
      | Node (Mul, product, _) -> alg (`Mul (List.map go product))
      | Node (Div, [s; t], _) -> alg (`Binop (`Div, go s, go t))
      | Node (Mod, [s; t], _) -> alg (`Binop (`Mod, go s, go t))
      | Node (Floor, [t], _) -> alg (`Unop (`Floor, go t))
      | Node (Neg, [t], _) -> alg (`Unop (`Neg, go t))
      | Node (Ite, [cond; bthen; belse], `TyReal)
      | Node (Ite, [cond; bthen; belse], `TyInt) ->
        alg (`Ite (cond, go bthen, go belse))
      | _ -> invalid_arg "eval: not a term"
    in
    go t

  let eval_partial ctx alg t =
    let alg' term =
      match alg term with
      | Some t -> t
      | None -> raise Quit
    in
    try Some (eval ctx alg' t)
    with Quit -> None

  let destruct ctx t = match t.obj with
    | Node (Real qq, [], _) -> `Real qq
    | Node (App _, _, `TyBool) -> invalid_arg "destruct: not a term"
    | Node (App func, args, `TyInt) | Node (App func, args, `TyReal) ->
      `App (func, args)
    | Node (Var (v, typ), [], _) ->
      begin match typ with
        | `TyInt -> `Var (v, `TyInt)
        | `TyReal -> `Var (v, `TyReal)
        | `TyBool -> invalid_arg "destruct: not a term"
      end
    | Node (Add, sum, _) -> `Add sum
    | Node (Mul, product, _) -> `Mul product
    | Node (Div, [s; t], _) -> `Binop (`Div, s, t)
    | Node (Mod, [s; t], _) -> `Binop (`Mod, s, t)
    | Node (Floor, [t], _) -> `Unop (`Floor, t)
    | Node (Neg, [t], _) -> `Unop (`Neg, t)
    | Node (Ite, [cond; bthen; belse], `TyReal)
    | Node (Ite, [cond; bthen; belse], `TyInt) ->
      `Ite (cond, bthen, belse)
    | _ -> invalid_arg "destruct: not a term"

  let pp = pp_expr
  let show ?(env=Env.empty) ctx t = ArkUtil.mk_show (pp ~env ctx) t
end

module Formula = struct
  type 'a t = 'a formula
  let equal s t = s.tag = t.tag
  let compare s t = Pervasives.compare s.tag t.tag
  let hash t = t.hcode

  let destruct ctx phi = match phi.obj with
    | Node (True, [], _) -> `Tru
    | Node (False, [], _) -> `Fls
    | Node (And, conjuncts, _) -> `And conjuncts
    | Node (Or, disjuncts, _) -> `Or disjuncts
    | Node (Not, [phi], _) -> `Not phi
    | Node (Exists (name, typ), [phi], _) -> `Quantify (`Exists, name, typ, phi)
    | Node (Forall (name, typ), [phi], _) -> `Quantify (`Forall, name, typ, phi)
    | Node (Eq, [s; t], _) -> `Atom (`Eq, s, t)
    | Node (Leq, [s; t], _) -> `Atom (`Leq, s, t)
    | Node (Lt, [s; t], _) -> `Atom (`Lt, s, t)
    | Node (Var (v, `TyBool), [], _) -> `Proposition (`Var v)
    | Node (App f, args, `TyBool) -> `Proposition (`App (f, args))
    | Node (Ite, [cond; bthen; belse], `TyBool) -> `Ite (cond, bthen, belse)
    | _ -> invalid_arg "destruct: not a formula"

  let rec eval ctx alg phi =
    match destruct ctx phi with
      | `Tru -> alg `Tru
      | `Fls -> alg `Fls
      | `Or disjuncts -> alg (`Or (List.map (eval ctx alg) disjuncts))
      | `And conjuncts -> alg (`And (List.map (eval ctx alg) conjuncts))
      | `Quantify (qt, name, typ, phi) ->
        alg (`Quantify (qt, name, typ, eval ctx alg phi))
      | `Not phi -> alg (`Not (eval ctx alg phi))
      | `Atom (op, s, t) -> alg (`Atom (op, s, t))
      | `Proposition p -> alg (`Proposition p)
      | `Ite (cond, bthen, belse) ->
        alg (`Ite (eval ctx alg cond, eval ctx alg bthen, eval ctx alg belse))

  let pp = pp_expr
  let show ?(env=Env.empty) ctx t = ArkUtil.mk_show (pp ~env ctx) t

  let quantify_closure quantify ctx phi =
    let vars = vars phi in
    let types = Array.make (Var.Set.cardinal vars) `TyInt in
    let rename =
      let n = ref (-1) in
      let map =
        Var.Set.fold (fun (v, typ) m ->
            incr n;
            types.(!n) <- typ;
            ArkUtil.Int.Map.add v (mk_var ctx (!n) typ) m
          )
          vars
          ArkUtil.Int.Map.empty
      in
      fun v -> ArkUtil.Int.Map.find v map
    in
    Array.fold_left
      (fun psi typ -> quantify typ psi)
      (substitute ctx rename phi)
      types

  let existential_closure ctx = quantify_closure (mk_exists ctx) ctx
  let universal_closure ctx = quantify_closure (mk_forall ctx) ctx

  let skolemize_free ctx phi =
    let skolem =
      Memo.memo (fun (i, typ) -> mk_const ctx (mk_symbol ctx typ))
    in
    let rec go sexpr =
      let (Node (label, children, _)) = sexpr.obj in
      match label with
      | Var (i, typ) -> skolem (i, (typ :> typ))
      | _ -> ctx.mk label (List.map go children)
    in
    go phi

  let prenex ctx phi =
    let negate_prefix =
      List.map (function
          | `Exists (name, typ) -> `Forall (name, typ)
          | `Forall (name, typ) -> `Exists (name, typ))
    in
    let combine phis =
      let f (qf_pre0, phi0) (qf_pre, phis) =
        let depth = List.length qf_pre in
        let depth0 = List.length qf_pre0 in
        let phis = List.map (decapture ctx depth depth0) phis in
        (qf_pre0@qf_pre, (decapture ctx 0 depth phi0)::phis)
      in
      List.fold_right f phis ([], [])
    in
    let alg = function
      | `Tru -> ([], mk_true ctx)
      | `Fls -> ([], mk_false ctx)
      | `Atom (`Eq, x, y) -> ([], mk_eq ctx x y)
      | `Atom (`Lt, x, y) -> ([], mk_lt ctx x y)
      | `Atom (`Leq, x, y) -> ([], mk_leq ctx x y)
      | `And conjuncts ->
        let (qf_pre, conjuncts) = combine conjuncts in
        (qf_pre, mk_and ctx conjuncts)
      | `Or disjuncts ->
        let (qf_pre, disjuncts) = combine disjuncts in
        (qf_pre, mk_or ctx disjuncts)
      | `Quantify (`Exists, name, typ, (qf_pre, phi)) ->
        (`Exists (name, typ)::qf_pre, phi)
      | `Quantify (`Forall, name, typ, (qf_pre, phi)) ->
        (`Forall (name, typ)::qf_pre, phi)
      | `Not (qf_pre, phi) -> (negate_prefix qf_pre, mk_not ctx phi)
      | `Proposition (`Var i) -> ([], mk_var ctx i `TyBool)
      | `Proposition (`App (p, args)) -> ([], mk_app ctx p args)
      | `Ite (cond, bthen, belse) ->
        begin match combine [cond; bthen; belse] with
          | (qf_pre, [cond; bthen; belse]) ->
            (qf_pre, mk_ite ctx cond bthen belse)
          | _ -> assert false
        end
    in
    let (qf_pre, matrix) = eval ctx alg phi in
    List.fold_right
      (fun qf phi ->
         match qf with
         | `Exists (name, typ) -> mk_exists ctx ~name typ phi
         | `Forall (name, typ) -> mk_forall ctx ~name typ phi)
      qf_pre
      matrix
end

let quantify_const ctx qt sym phi =
  let typ = match typ_symbol ctx sym with
    | `TyInt -> `TyInt
    | `TyReal -> `TyReal
    | `TyBool -> `TyBool
    | `TyFun _ ->
      begin match qt with
        | `Forall ->
          invalid_arg "mk_forall_const: not a first-order constant"
        | `Exists ->
          invalid_arg "mk_exists_const: not a first-order constant"
      end
  in
  let replacement = mk_var ctx 0 typ in
  let subst k =
    if k = sym then replacement
    else mk_const ctx k
  in
  let psi = substitute_const ctx subst (decapture ctx 0 1 phi) in
  match qt with
  | `Forall -> mk_forall ctx ~name:(show_symbol ctx sym) typ psi
  | `Exists -> mk_exists ctx ~name:(show_symbol ctx sym) typ psi

let mk_exists_const ctx = quantify_const ctx `Exists
let mk_forall_const ctx = quantify_const ctx `Forall

let node_typ symbols label children =
  match label with
  | Real qq ->
    begin match QQ.to_zz qq with
      | Some _ -> `TyInt
      | None -> `TyReal
    end
  | Var (_, typ) -> typ
  | App func ->
    begin match snd (DynArray.get symbols func) with
      | `TyFun (args, ret) ->
        if List.length args != List.length children then
          invalid_arg "Arity mis-match in function application";
        if (BatList.for_all2
              (fun typ { obj = Node (_, _, typ') } -> subtype typ' typ)
              args
              children)
        then
          ret
        else
          invalid_arg "Mis-matched types in function application"
      | `TyInt when children = [] -> `TyInt
      | `TyReal when children = [] -> `TyReal
      | `TyBool when children = [] -> `TyBool
      | _ -> invalid_arg "Application of a non-function symbol"
    end
  | Forall (_, _) | Exists (_, _) | And | Or | Not
  | True | False | Eq | Leq | Lt  -> `TyBool
  | Floor -> `TyInt
  | Div -> `TyReal
  | Add | Mul | Mod | Neg ->
    List.fold_left (fun typ { obj = Node (_, _, typ') } ->
        match typ, typ' with
        | `TyInt, `TyInt -> `TyInt
        | `TyInt, `TyReal | `TyReal, `TyInt | `TyReal, `TyReal -> `TyReal
        | _, _ -> assert false)
      `TyInt
      children
  | Ite ->
    begin match children with
      | [cond; bthen; belse] ->
        begin match cond.obj, bthen.obj, belse.obj with
          | Node (_, _, `TyBool), Node (_, _, `TyBool), Node (_, _, `TyBool) ->
            `TyBool
          | Node (_, _, `TyBool), Node (_, _, `TyInt), Node (_, _, `TyInt) ->
            `TyInt
          | Node (_, _, `TyBool), Node (_, _, `TyInt), Node (_, _, `TyReal)
          | Node (_, _, `TyBool), Node (_, _, `TyReal), Node (_, _, `TyInt)
          | Node (_, _, `TyBool), Node (_, _, `TyReal), Node (_, _, `TyReal) ->
            `TyReal
          | _, _, _ -> invalid_arg "ill-typed if-then-else"
        end
      | _ -> assert false
    end

let term_typ _ node =
  match node.obj with
  | Node (_, _, `TyInt) -> `TyInt
  | Node (_, _, `TyReal) -> `TyReal
  | Node (_, _, `TyBool) -> invalid_arg "term_typ: not an arithmetic term"

let expr_typ _ node =
  match node.obj with
  | Node (_, _, `TyInt) -> `TyInt
  | Node (_, _, `TyReal) -> `TyReal
  | Node (_, _, `TyBool) -> `TyBool

type 'a rewriter = ('a, typ_fo) expr -> ('a, typ_fo) expr

let rec nnf_rewriter ctx sexpr =
  match sexpr.obj with
  | Node (Not, [phi], _) ->
    begin match phi.obj with
      | Node (Not, [psi], _) -> nnf_rewriter ctx psi
      | Node (And, conjuncts, _) -> mk_or ctx (List.map (mk_not ctx) conjuncts)
      | Node (Or, conjuncts, _) -> mk_and ctx (List.map (mk_not ctx) conjuncts)
      | Node (Leq, [s; t], _) -> mk_lt ctx t s
      | Node (Eq, [s; t], _) ->
        begin match s.obj, t.obj with
          | Node (Mod, _, _), Node (Real x, _, _) when QQ.equal x QQ.zero ->
            mk_lt ctx t s
          | _, _ ->
            mk_or ctx [mk_lt ctx s t; mk_lt ctx t s]
        end
      | Node (Lt, [s; t], _) -> mk_leq ctx t s
      | Node (Exists (name, typ), [psi], _) ->
        mk_forall ctx ~name typ (mk_not ctx psi)
      | Node (Forall (name, typ), [psi], _) ->
        mk_exists ctx ~name typ (mk_not ctx psi)
      | Node (Ite, [cond; bthen; belse], `TyBool) ->
        mk_ite ctx cond (mk_not ctx bthen) (mk_not ctx belse)
      | _ -> sexpr
    end
  | _ -> sexpr

let rec rewrite ctx ?down:(down=fun x -> x) ?up:(up=fun x -> x) sexpr =
  let (Node (label, children, typ)) = (down sexpr).obj in
  up (ctx.mk label (List.map (rewrite ctx ~down ~up) children))

let eliminate_ite ctx phi =
  let rec map_ite f ite =
    match ite with
    | `Term t -> f t
    | `Ite (cond, bthen, belse) ->
      `Ite (cond, map_ite f bthen, map_ite f belse)
  in
  let mk_ite cond bthen belse =
    mk_or ctx [mk_and ctx [cond; bthen];
               mk_and ctx [mk_not ctx cond; belse]]
  in
  let rec ite_formula ite =
    match ite with
    | `Term phi -> phi
    | `Ite (cond, bthen, belse) ->
      mk_ite cond (ite_formula bthen) (ite_formula belse)
  in
  let mk_atom op =
    match op with
    | `Eq -> mk_eq ctx
    | `Leq -> mk_leq ctx
    | `Lt -> mk_lt ctx
  in
  let rec promote_ite term =
    match Term.destruct ctx term with
    | `Ite (cond, bthen, belse) ->
      `Ite (elim_ite cond, promote_ite bthen, promote_ite belse)
    | `Real _ | `Var (_, _) -> `Term term
    | `Add xs -> map_ite (fun xs -> `Term (mk_add ctx xs)) (ite_list xs)
    | `Mul xs -> map_ite (fun xs -> `Term (mk_mul ctx xs)) (ite_list xs)
    | `Binop (`Div, x, y) ->
      let promote_y = promote_ite y in
      map_ite
        (fun t -> map_ite (fun s -> `Term (mk_div ctx t s)) promote_y)
        (promote_ite x)
    | `Binop (`Mod, x, y) ->
      let promote_y = promote_ite y in
      map_ite
        (fun t -> map_ite (fun s -> `Term (mk_mod ctx t s)) promote_y)
        (promote_ite x)
    | `Unop (`Neg, x) ->
      map_ite (fun t -> `Term (mk_neg ctx t)) (promote_ite x)
    | `Unop (`Floor, x) ->
      map_ite (fun t -> `Term (mk_floor ctx t)) (promote_ite x)
    | `App (func, args) ->
      List.fold_right (fun x rest ->
          match Expr.refine ctx x with
          | `Formula phi ->
            let phi = elim_ite phi in
            map_ite (fun xs -> `Term (phi::xs)) rest
          | `Term t ->
            map_ite
              (fun t -> map_ite (fun xs -> `Term (t::xs)) rest)
              (promote_ite t))
        args
        (`Term [])
      |> map_ite (fun args -> `Term (mk_app ctx func args))
  and ite_list xs =
    List.fold_right (fun x ite ->
        map_ite
          (fun x_term -> map_ite (fun xs -> `Term (x_term::xs)) ite)
          (promote_ite x))
      xs
      (`Term [])
  and elim_ite phi =
    let alg = function
      | `Tru -> mk_true ctx
      | `Fls -> mk_false ctx
      | `And xs -> mk_and ctx xs
      | `Or xs -> mk_or ctx xs
      | `Not phi  -> mk_not ctx phi
      | `Quantify (`Exists, name, typ, phi) -> mk_exists ctx ~name typ phi
      | `Quantify (`Forall, name, typ, phi) -> mk_forall ctx ~name typ phi
      | `Ite (cond, bthen, belse) -> mk_ite cond bthen belse
      | `Atom (op, s, t) ->
        let promote_t = promote_ite t in
        map_ite
          (fun s -> map_ite (fun t -> `Term (mk_atom op s t)) promote_t)
          (promote_ite s)
        |> ite_formula
      | `Proposition (`Var i) -> mk_var ctx i `TyBool
      | `Proposition (`App (func, args)) ->
        List.fold_right (fun x rest ->
            match Expr.refine ctx x with
            | `Formula phi ->
              let phi = elim_ite phi in
              map_ite (fun xs -> `Term (phi::xs)) rest
            | `Term t ->
              map_ite
                (fun t -> map_ite (fun xs -> `Term (t::xs)) rest)
                (promote_ite t))
          args
          (`Term [])
        |> map_ite (fun args -> `Term (mk_app ctx func args))
        |> ite_formula
    in
    Formula.eval ctx alg phi
  in
  elim_ite phi

let rec pp_smtlib2 ?(env=Env.empty) ctx formatter expr =
  let open Format in
  let pp_sep = pp_print_space in

  (* Legal characters in an SMTLIB2 symbol *)
  let legal_char x =
    BatChar.is_letter x || BatChar.is_digit x
    || BatString.contains "~!@$%^&*_-+=<>.?/" x
  in
  (* Convert a string to a valid SMTLIB2 symbol *)
  let symbol_of_string name =
    if BatEnum.for_all legal_char (BatString.enum name) then
      name
    else
      let replaced =
        BatString.map (fun c ->
            if legal_char c || BatString.contains " \"#'(),;:`{}" c then
              c
            else
              '?')
          name
      in
      "|" ^ replaced ^ "|"
  in
    
  (* find a unique string that can be used to identify each symbol *)
  let strings = Hashtbl.create 991 in
  let symbol_name = Hashtbl.create 991 in
  Symbol.Set.iter (fun symbol ->
      let name = symbol_of_string (fst (DynArray.get ctx.symbols symbol)) in
      if Hashtbl.mem strings name then
        let rec go n =
          let name' = name ^ (string_of_int n) in
          if Hashtbl.mem strings name' then
            go (n + 1)
          else begin
            Hashtbl.add strings name' ();
            Hashtbl.add symbol_name symbol name'
          end
        in
        go 0
      else begin
        Hashtbl.add strings name ();
        Hashtbl.add symbol_name symbol name
      end)
    (symbols expr);

  fprintf formatter "@[<v 0>";
  (* print declarations *)
  symbol_name |> Hashtbl.iter (fun symbol name ->
      let pp_typ_fo formatter = function
        | `TyReal -> pp_print_string formatter "Real"
        | `TyInt -> pp_print_string formatter "Int"
        | `TyBool -> pp_print_string formatter "Bool"
      in        
      match typ_symbol ctx symbol with
      | `TyReal -> fprintf formatter "(declare-const %s Real)@;" name
      | `TyInt -> fprintf formatter "(declare-const %s Int)@;" name
      | `TyBool -> fprintf formatter "(declare-const %s Bool)@;" name
      | `TyFun (args, ret) ->
        fprintf formatter "(declare-fun %s (%a) %a)@;"
          name
          (ArkUtil.pp_print_enum ~pp_sep pp_typ_fo) (BatList.enum args)
          pp_typ_fo ret
    );

  let rec go env formatter expr =
    let Node (label, children, _) = expr.obj in
    match label, children with
    | Real qq, [] ->
      let (num, den) = QQ.to_zzfrac qq in
      if ZZ.equal den ZZ.one then
        ZZ.pp formatter num
      else
        fprintf formatter "(/ %a %a)"
          ZZ.pp num
          ZZ.pp den
    | App k, [] ->
      pp_print_string formatter (Hashtbl.find symbol_name k)
    | App func, args ->
      fprintf formatter "(%s %a)"
        (Hashtbl.find symbol_name func)
        (ArkUtil.pp_print_enum ~pp_sep (go env)) (BatList.enum args)
    | Var (v, typ), [] ->
      (try fprintf formatter "?%s_%d" (Env.find env v) v
       with Not_found -> fprintf formatter "[free:%d]" v)
    | Add, terms ->
      fprintf formatter "(+ @[";
      ArkUtil.pp_print_enum
        ~pp_sep
        (go env)
        formatter
        (BatList.enum terms);
      fprintf formatter "@])"
    | Mul, terms ->
      fprintf formatter "(* @[";
      ArkUtil.pp_print_enum
        ~pp_sep
        (go env)
        formatter
        (BatList.enum terms);
      fprintf formatter "@])"
    | Div, [s; t] ->
      fprintf formatter "(/@[%a@ %a@])"
        (go env) s
        (go env) t
    | Mod, [s; t] ->
      fprintf formatter "(mod @[%a@ %a@])"
        (go env) s
        (go env) t
    | Floor, [t] ->
      fprintf formatter "(floor @[%a@])" (go env) t
    | Neg, [{obj = Node (Real qq, [], _)}] ->
      QQ.pp formatter (QQ.negate qq)
    | Neg, [{obj = Node (App _, _, _)} as t]
    | Neg, [t] -> fprintf formatter "(- @[%a@])" (go env) t
    | True, [] -> pp_print_string formatter "true"
    | False, [] -> pp_print_string formatter "false"
    | Not, [phi] ->
      fprintf formatter "(not @[%a@])" (go env) phi
    | And, conjuncts ->
      fprintf formatter "(and @[";
      ArkUtil.pp_print_enum
        ~pp_sep
        (go env)
        formatter
        (BatList.enum (List.concat (List.map (flatten_sexpr And) conjuncts)));
      fprintf formatter "@])"
    | Or, disjuncts ->
      fprintf formatter "(or @[";
      ArkUtil.pp_print_enum
        ~pp_sep
        (go env)
        formatter
        (BatList.enum (List.concat (List.map (flatten_sexpr Or) disjuncts)));
      fprintf formatter "@])"
    | Eq, [x; y] ->
      fprintf formatter "(= @[%a %a@])"
        (go env) x
        (go env) y
    | Leq, [x; y] ->
      fprintf formatter "(<= @[%a %a@])"
        (go env) x
        (go env) y
    | Lt, [x; y] ->
      fprintf formatter "(< @[%a %a@])"
        (go env) x
        (go env) y
    | Exists (name, typ), [psi] | Forall (name, typ), [psi] ->
      let (quantifier_name, varinfo, psi) =
        match label with
        | Exists (_, _) ->
          let (varinfo, psi) = flatten_existential psi in
          ("exists", (name, typ)::varinfo, psi)
        | Forall (_, _) ->
          let (varinfo, psi) = flatten_universal psi in
          ("forall", (name, typ)::varinfo, psi)
        | _ -> assert false
      in
      let env =
        List.fold_left (fun env (x,_) -> Env.push x env) env varinfo
      in
      fprintf formatter "(@[%s@ (" quantifier_name;
      ArkUtil.pp_print_enum
        ~pp_sep
        (fun formatter (name, typ) ->
           fprintf formatter "(%s %a)" name pp_typ typ)
        formatter
        (BatList.enum varinfo);
      fprintf formatter ")@ %a@])" (go env) psi
    | Ite, [cond; bthen; belse] ->
      fprintf formatter "(ite @[%a@ %a@ %a@])"
        (go env) cond
        (go env) bthen
        (go env) belse
    | _ -> failwith "pp_smtlib2: ill-formed expression"
  in
  fprintf formatter "(assert %a)@;(check-sat)@]" (go env) expr;

module Infix (C : sig
    type t
    val context : t context
  end) =
struct
  let ( ! ) = mk_not C.context
  let ( && ) x y = mk_and C.context [x; y]
  let ( || ) x y = mk_or C.context [x; y]
  let ( < ) = mk_lt C.context
  let ( <= ) = mk_leq C.context
  let ( = ) = mk_eq C.context
  let tru = mk_true C.context
  let fls = mk_false C.context
      
  let ( + ) x y = mk_add C.context [x; y]
  let ( - ) x y = mk_add C.context [x; mk_neg C.context y]
  let ( * ) x y = mk_mul C.context [x; y]
  let ( / ) = mk_div C.context
  let ( mod ) = mk_mod C.context

  let const = mk_const C.context
  let forall = mk_forall C.context
  let exists = mk_exists C.context
  let var = mk_var C.context
end

module type Context = sig
  type t (* magic type parameter unique to this context *)
  val context : t context
  type term = (t, typ_arith) expr
  type formula = (t, typ_bool) expr

  val mk_symbol : ?name:string -> typ -> symbol
  val mk_const : symbol -> ('a, 'typ) expr
  val mk_app : symbol -> ('a, 'b) expr list -> ('a, 'typ) expr
  val mk_var : int -> typ_fo -> ('a, 'typ) expr
  val mk_add : term list -> term
  val mk_mul : term list -> term
  val mk_div : term -> term -> term
  val mk_idiv : term -> term -> term
  val mk_mod : term -> term -> term
  val mk_real : QQ.t -> term
  val mk_floor : term -> term
  val mk_neg : term -> term
  val mk_sub : term -> term -> term
  val mk_forall : ?name:string -> typ_fo -> formula -> formula
  val mk_exists : ?name:string -> typ_fo -> formula -> formula
  val mk_forall_const : symbol -> formula -> formula
  val mk_exists_const : symbol -> formula -> formula
  val mk_and : formula list -> formula
  val mk_or : formula list -> formula
  val mk_not : formula -> formula
  val mk_eq : term -> term -> formula
  val mk_lt : term -> term -> formula
  val mk_leq : term -> term -> formula
  val mk_true : formula
  val mk_false : formula
  val mk_ite : formula -> (t, 'a) expr -> (t, 'a) expr -> (t, 'a) expr
end

module ImplicitContext(C : sig
    type t
    val context : t context
  end) = struct
  open C
  let mk_symbol = mk_symbol context
  let mk_const = mk_const context
  let mk_app = mk_app context
  let mk_var = mk_var context
  let mk_add = mk_add context
  let mk_mul = mk_mul context
  let mk_div = mk_div context
  let mk_idiv = mk_idiv context
  let mk_mod = mk_mod context
  let mk_real = mk_real context
  let mk_floor = mk_floor context
  let mk_neg = mk_neg context
  let mk_sub = mk_sub context
  let mk_forall = mk_forall context
  let mk_exists = mk_exists context
  let mk_forall_const = mk_forall_const context
  let mk_exists_const = mk_exists_const context
  let mk_and = mk_and context
  let mk_or = mk_or context
  let mk_not = mk_not context
  let mk_eq = mk_eq context
  let mk_lt = mk_lt context
  let mk_leq = mk_leq context
  let mk_true = mk_true context
  let mk_false = mk_false context
  let mk_ite = mk_ite context
end

module MakeContext () = struct
  type t = unit
  type term = (t, typ_arith) expr
  type formula = (t, typ_bool) expr

  let context =
    let hashcons = HC.create 991 in
    let symbols = DynArray.make 512 in
    let mk label children =
      let typ = node_typ symbols label children in
      HC.hashcons hashcons (Node (label, children, typ))
    in
    let named_symbols = Hashtbl.create 991 in
    { hashcons; symbols; named_symbols; mk }

  include ImplicitContext(struct
      type t = unit
      let context = context
    end)
end

module MakeSimplifyingContext () = struct
  type t = unit
  type term = (t, typ_arith) expr
  type formula = (t, typ_bool) expr

  let context =
    let hashcons = HC.create 991 in
    let symbols = DynArray.make 512 in
    let named_symbols = Hashtbl.create 991 in
    let true_ = HC.hashcons hashcons (Node (True, [], `TyBool)) in
    let false_ = HC.hashcons hashcons (Node (False, [], `TyBool)) in
    let rec mk label children =
      let hc label children =
        let typ = node_typ symbols label children in
        HC.hashcons hashcons (Node (label, children, typ))
      in
      match label, children with
      | Lt, [x; y] ->
        begin match x.obj, y.obj with
          | Node (Real xv, [], _), Node (Real yv, [], _) ->
            if QQ.lt xv yv then true_ else false_
          | _ -> hc label [x; y]
        end

      | Leq, [x; y] ->
        begin match x.obj, y.obj with
          | Node (Real xv, [], _), Node (Real yv, [], _) ->
            if QQ.leq xv yv then true_ else false_
          | _ -> hc label [x; y]
        end

      | Eq, [x; y] ->
        begin match x.obj, y.obj with
          | Node (Real xv, [], _), Node (Real yv, [], _) ->
            if QQ.equal xv yv then true_ else false_
          | _ -> hc label [x; y]
        end

      | And, conjuncts ->
        if List.exists is_false conjuncts then
          false_
        else
          begin
            match List.filter (not % is_true) conjuncts with
            | [] -> true_
            | [x] -> x
            | conjuncts -> hc And conjuncts
          end

      | Or, disjuncts ->
          if List.exists is_true disjuncts then
            true_
          else
            begin
              match List.filter (not % is_false) disjuncts with
              | [] -> false_
              | [x] -> x
              | disjuncts -> hc Or disjuncts
            end

      | Not, [phi] when is_true phi -> false_
      | Not, [phi] when is_false phi -> true_
      | Not, [phi] ->
        begin match phi.obj with
          | Node (Not, [psi], _) -> psi
          | _ -> hc Not [phi]
        end

      | Add, xs ->
        begin match List.filter (not % is_zero) xs with
          | [] -> mk (Real QQ.zero) []
          | [x] -> x
          | xs -> hc Add xs
        end

      | Mul, xs ->
        let (const, non_const) =
          List.fold_right (fun x (const, non_const) ->
              match x.obj with
              | Node (Real xv, [], _) -> (QQ.mul xv const, non_const)
              | _ -> (const, x::non_const))
            xs
            (QQ.one, [])
        in
        if QQ.equal const QQ.zero then
          mk (Real QQ.zero) []
        else if non_const = [] then
          mk (Real const) []
        else if QQ.equal const QQ.one then
          hc Mul non_const
        else
          hc Mul ((mk (Real const) [])::non_const)

      | Neg, [x] ->
        begin match x.obj with
          | Node (Real xv, [], _) -> mk (Real (QQ.negate xv)) []
          | Node (Neg, [y], _) -> y
          | _ -> hc Neg [x]
        end

      | Floor, [x] ->
        begin match x.obj with
          | Node (Real xv, [], _) -> mk (Real (QQ.of_zz (QQ.floor xv))) []
          | _ -> hc Floor [x]
        end

      | Div, [num; den] ->
        begin match num.obj, den.obj with
          | _, Node (Real d, [], _) when QQ.equal d QQ.zero ->
            hc Div [num; den]
          | (Node (Real num, [], _), Node (Real den, [], _)) ->
            mk (Real (QQ.div num den)) []
          | _, Node (Real den, [], _) when QQ.equal den QQ.one -> num
          | _, _ -> hc Div [num; den]
        end

      | Ite, [cond; bthen; _] when is_true cond -> bthen
      | Ite, [cond; _; belse] when is_false cond -> belse
      | Ite, [_; x; y] when x.tag = y.tag -> x

      | _, _ -> hc label children
    in
    { hashcons; symbols; named_symbols; mk }

  include ImplicitContext(struct
      type t = unit
      let context = context
    end)
end
