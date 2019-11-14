open Syntax

type c_ast =
  | Empty
  | Const of string
  | Variable of string (* 変数 *)
  | VarDec of Type.t * string (* 変数宣言 *)
  | Assignment of Type.t option * string * c_ast (* 変数への代入. もしType.tがNoneならば宣言済みの変数. そうでなければ変数宣言と同時に代入 *)
  | Binop of string * c_ast * c_ast
  | Call of string * c_ast list
  | If of (Type.t * string) (* If式の結果に対応する変数名とその型 *)
          * (c_ast * c_ast) (* cond式のC言語でのAST(pre,post) *)
          * (c_ast * c_ast) (* then (pre,post) *)
          * (c_ast * c_ast) (* else (pre,post) *)
  | CodeList of c_ast list

let rec string_of_c_ast (ast : c_ast) : string =
  match ast with
  | Empty ->
      "Empty"
  | Const s ->
      Printf.sprintf "Const[ %s ]" s
  | VarDec (t,i) -> Printf.sprintf "VarDec[ %s ][ %s ]" (Type.of_string t) i
  | Variable v ->
      Printf.sprintf "Var[ %s ]" v
  | Assignment (t, var, ast) ->
      let typename = match t with
      | None -> "None"
      | Some(t) -> Type.of_string t
      in
      Printf.sprintf "Assignment[ %s ][ %s ][ %s ]" typename var (string_of_c_ast ast)
  | Binop (op, ast1, ast2) ->
      Printf.sprintf "Binop[ %s ][ %s ][ %s ]" op (string_of_c_ast ast1)
        (string_of_c_ast ast2)
  | Call (f, args) ->
      Printf.sprintf "Call[ %s ][ %s ]" f
        (List.map string_of_c_ast args |> String.concat " , ")
  | If(_,_,_,_) -> "If [] []"
  | CodeList codes ->
      List.map string_of_c_ast codes |> String.concat " :: "

let unique_index = ref 0

let get_unique_name () : string =
  let id = string_of_int !unique_index in
  unique_index := !unique_index + 1 ;
  "tmp_" ^ id

let header_list = ["stdio.h"; "stdlib.h"]

let header_code () =
  List.map (fun s -> "#include<" ^ s ^ ">") header_list |> String.concat "\n"

let global_variable (ast : Syntax.ast) (prg : Module.program) =
  let input =
    List.map
      (fun (id, typ) -> Printf.sprintf "%s %s[2];" (Type.of_string typ) id)
      ast.in_nodes
    |> String.concat "\n"
  in
  let node =
    List.filter_map
      (function
        | Syntax.Node ((i, t), _, _) ->
            Some (Printf.sprintf "%s %s[2];" (Type.of_string t) i)
        | _ ->
            None)
      ast.definitions
    |> String.concat "\n"
  in
  let gnode =
    List.filter_map
      (function
        | Syntax.GNode ((i, t), _, _, _) ->
            Some (Printf.sprintf "%s* g_%s[2];" (Type.of_string t) i)
        | _ ->
            None)
      ast.definitions
    |> String.concat "\n"
  in
  input ^ "\n" ^ node ^ "\n" ^ gnode

let rec expr_to_clang (e : expr) : c_ast * c_ast =
  match e with
  | EConst e ->
      (Empty, Const (Syntax.string_of_const e))
  | Eid i ->
      (Empty, Variable (i ^ "[turn]"))
  | EAnnot(id,annot) ->
      (Empty, Variable (id ^ "[turn^1]"))
  | Ebin (op, e1, e2) ->
      let op_symbol = string_of_binop op in
      let pre1, cur1 = expr_to_clang e1 in
      let pre2, cur2 = expr_to_clang e2 in
      (CodeList [pre1; pre2], Binop (op_symbol, cur1, cur2))
  | EApp (f, args) ->
      let maped = List.map expr_to_clang args in
      let pre : c_ast list = List.map (fun (p, _) -> p) maped in
      let a : c_ast list = List.map (fun (_, a) -> a) maped in
      (CodeList pre, Call (f, a))
  | Eif(cond_expr, then_expr, else_expr) ->  (* TODO 実装 *)
      let res_var = get_unique_name () in (* 型は? *)
      (If((Type.TInt,res_var), expr_to_clang cond_expr, expr_to_clang then_expr, expr_to_clang else_expr), Variable(res_var))


let rec code_of_c_ast (ast : c_ast) (tabs : int) : string =
  let tab = String.make tabs '\t' in
  match ast with
  | Empty ->
      ""
  | Const s ->
      s
  | Variable v ->
      v
  | VarDec (t,v) ->
      Printf.sprintf "%s %s;" (Type.of_string t) v
  | Assignment (_, var, ca) ->
      (* int a = ??? *)
      let right = code_of_c_ast ca tabs in
      tab ^ var ^ "=" ^ right ^ ";"
  | Binop (op, ast1, ast2) ->
      Printf.sprintf "%s %s %s" (code_of_c_ast ast1 0) op
        (code_of_c_ast ast2 0)
  | Call(f,args) -> 
      Printf.sprintf "%s(%s)" f (List.map (fun ast -> code_of_c_ast ast 0) args |> String.concat ", ")
  | If( (t, res),
        (cond_pre,cond_post),
        (then_pre,then_post),
        (else_pre,else_post) ) ->
          let cond_post_code = code_of_c_ast cond_pre tabs in
          let if_var_dec = tab ^ (Printf.sprintf "%s %s;\n" (Type.of_string t) res) in (* Ifの結果の宣言 *)
          let cond_var = get_unique_name () in
          let cond_var_dec = tab ^ (Printf.sprintf "%s %s = %s;\n" (Type.of_string Type.TBool) cond_var (code_of_c_ast cond_post 0) )in (* 条件の結果をcond_varに保存 *)
          cond_post_code ^ if_var_dec ^ cond_var_dec (* TODO 実装未完了 *)
  | CodeList(lst) -> 
      List.iter (fun ast -> Printf.printf "--> %s\n" (string_of_c_ast ast) ) lst;
      List.filter_map (function | Empty -> None
                                | ast -> Some( code_of_c_ast ast tabs )) lst |> String.concat "\n"

(* ノード更新関数を生やす関数 *)
let generate_node_update_function (name : string) (expr : Syntax.expr) =
  let declare = Printf.sprintf "void %s_update(){\n" name in
  let foward, backward = expr_to_clang expr in
  let code1 = code_of_c_ast foward 1 in
  let code2 = code_of_c_ast backward 0 in
  Printf.printf "----- %s ----- \n" name ;
  Printf.printf "expr: %s\n" (string_of_expr expr) ;
  Printf.printf "foward : %s\n" (string_of_c_ast foward) ;
  Printf.printf "backward : %s\n" (string_of_c_ast backward) ;
  Printf.printf "cod1: -> %d <-\n" (String.length code1);
  Printf.printf "cod2: -> %d : %s <-\n" (String.length code2) code2;
  String.concat ""
    [declare ; code1 ^ (if code1 = "" then "" else "\n") ; Printf.sprintf "\t%s[turn] = %s ;" name code2; "\n}"]

let setup_code (ast : Syntax.ast) (prg : Module.program) : string =
  (* GNodeの初期化 *)
  let init_gnode =
    List.filter_map
      (function
        | GNode ((i, t), n, init, _) ->
            let malloc =
              Printf.sprintf
                "\tfor(int i=0;i<2;i++) \
                 cudaMalloc((void**)&g_%s[i],%d*sizeof(%s));"
                i n (Type.of_string t)
            in
            if Option.is_none init then Some malloc
            else
              let tmp = get_unique_name () in
              let preast, curast = expr_to_clang (Option.get init) in
              let precode = code_of_c_ast preast 1 in
              let curcode =
                "\tint " ^ tmp ^ " = " ^ code_of_c_ast curast 1 ^ ";"
              in
              let ini_code =
                Printf.sprintf "\tcudaMemSet(%s[1],%s,sizeof(%s)*%d)" i tmp
                  (Type.of_string t) n
              in
              Some
                ( malloc ^ "\n" ^ precode
                ^ (if precode = "" then "" else "\n")
                ^ curcode ^ "\n" ^ ini_code )
        | _ ->
            None)
      ast.definitions
    |> String.concat "\n"
  in
  let init_node =
    List.filter_map
      (function
        | Node ((i, t), init, _) ->
            if Option.is_none init then None
              (* 初期化指定子が無い場合 *)
            else
              let preast, curast = expr_to_clang (Option.get init) in
              let precode = code_of_c_ast preast 1 in
              let curcode = code_of_c_ast curast 1 in
              Some
                ( precode
                ^ (if precode = "" then "" else "\n")
                ^ "\t" ^ i ^ "[1] = " ^ curcode )
        | _ ->
            None)
      ast.definitions
    |> String.concat "\n"
  in
  "void setup(){\n" ^ "\tturn=0;\n" ^ init_node
  ^ (if init_node = "" then "" else "\n")
  ^ init_gnode ^ "\n" ^ "}"

let main_code = "int main()\n{\n  setup();\n  loop();\n}"

let code_of_ast : Syntax.ast -> Module.program -> string =
 fun ast prg ->
  let header = header_code () in
  let variables = global_variable ast prg in
  let node_update =
    List.filter_map
      (function
        | Node ((i, t), _, e) ->
            Some (generate_node_update_function i e)
        | _ ->
            None)
      ast.definitions
    |> String.concat "\n\n"
  in
  let main = main_code in
  let setup = setup_code ast prg in
  String.concat "\n\n" [header; variables; node_update; setup; main]
