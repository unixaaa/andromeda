(** Equality checking and weak-head-normal-forms *)

(** An option monad on top of Runtime.comp, which only uses Runtime.bind when necessary. *)
module Opt = struct
  type 'a opt =
    { k : 'r. ('a -> 'r Runtime.comp) -> 'r Runtime.comp -> 'r Runtime.comp }

  let return x =
    { k = fun sk _ -> sk x }

  let (>?=) m f =
    { k = fun sk fk -> m.k (fun x -> (f x).k sk fk) fk }

  let lift (m : 'a Runtime.comp) : 'a opt =
    { k = fun sk _ -> Runtime.bind m sk }

  let fail =
    { k = fun _ fk -> fk }

  let run m =
    m.k (fun x -> Runtime.return (Some x)) (Runtime.return None)
end

(*
let (>>=) = Runtime.bind
*)

let (>?=) = Opt.(>?=)

let (>!=) m f = (Opt.lift m) >?= f

module Internals = struct

(** Compare two types *)
let equal ~loc j1 j2 =
  match Jdg.alpha_equal_eq_term ~loc j1 j2 with
    | Some eq -> Opt.return eq
    | None ->
      Predefined.operation_equal ~loc j1 j2 >!= begin function
        | Some juser ->
          Runtime.lookup_typing_signature >!= fun signature ->
          let target = Jdg.form_ty ~loc signature (Jdg.Eq (j1, j2)) in
          begin match Jdg.alpha_equal_eq_ty ~loc target (Jdg.typeof juser) with
            | Some _ ->
              let eq = Jdg.reflect ~loc juser in
              Opt.return eq
            | None -> Opt.lift (Runtime.(error ~loc (InvalidEqual target)))
          end
        | None -> Opt.fail
      end

let equal_ty ~loc j1 j2 =
  equal ~loc (Jdg.term_of_ty j1) (Jdg.term_of_ty j2) >?= fun eq ->
  let eq = Jdg.is_type_equality ~loc eq in
  Opt.return eq

let coerce ~loc je jt =
  let je_ty = Jdg.typeof je in
  match Jdg.alpha_equal_eq_ty ~loc je_ty jt with

  | Some _ ->
     Opt.return je

  | None ->
     Predefined.operation_coerce ~loc je jt >!=
       begin function

       | Predefined.NotCoercible -> Opt.fail

       | Predefined.Convertible eq ->
          let eq_lhs = Jdg.eq_ty_side Jdg.LEFT eq
          and eq_rhs = Jdg.eq_ty_side Jdg.RIGHT eq in
          begin
            match Jdg.alpha_equal_eq_ty ~loc je_ty eq_lhs,
                  Jdg.alpha_equal_eq_ty ~loc jt eq_rhs
            with
            | Some _, Some _ ->
               Opt.return (Jdg.convert ~loc je eq)
            | (None, Some _ | Some _, None | None, None) ->
               Runtime.(error ~loc (InvalidConvertible (je_ty, jt, eq)))
          end

       | Predefined.Coercible je ->
          begin
            match Jdg.alpha_equal_eq_ty ~loc (Jdg.typeof je) jt with
            | Some _ ->
               Opt.return je
            | None ->
               Runtime.(error ~loc (InvalidCoerce (jt, je)))
          end
       end


let coerce_fun ~loc je =
  let jt = Jdg.typeof je in
  match Jdg.shape_prod jt with

  | Some (a, b) -> Opt.return (je, a, b)

  | None ->
     Predefined.operation_coerce_fun ~loc je >!=
     begin function

       | Predefined.NotCoercible ->
          Opt.fail

       | Predefined.Convertible eq ->
          let eq_lhs = Jdg.eq_ty_side Jdg.LEFT eq
          and eq_rhs = Jdg.eq_ty_side Jdg.RIGHT eq in
          begin
            match Jdg.alpha_equal_eq_ty ~loc jt eq_lhs with
              | Some _ ->
                 begin
                   match Jdg.shape_prod eq_rhs with
                   | Some (a, b) ->
                      let je = Jdg.convert ~loc je eq in
                      Opt.return (je, a, b)
                   | None ->
                      Runtime.(error ~loc (InvalidFunConvertible (jt, eq)))
                 end

              | None ->
                 Runtime.(error ~loc (InvalidFunConvertible (jt, eq)))
          end

       | Predefined.Coercible je ->
          begin
            let jt = Jdg.typeof je in
            match Jdg.shape_prod jt with
            | Some (a, b) ->
               Opt.return (je, a, b)
            | None ->
               Runtime.(error ~loc (InvalidFunCoerce je))
          end

     end


let as_eq_alpha t =
  match Jdg.shape_ty t with
    | Jdg.Eq (e1, e2) -> Some (e1, e2)
    | _ -> None

let as_eq ~loc t =
  match as_eq_alpha t with
    | Some (e1, e2) -> Opt.return (Jdg.reflexivity_ty t, e1, e2)
    | None ->
      Predefined.operation_as_eq ~loc t >!=
      begin function
        | None ->
          Opt.fail
        | Some juser ->
          let jt = Jdg.typeof juser in
          begin match as_eq_alpha jt with
            | None ->
               Opt.lift Runtime.(error ~loc (InvalidAsEquality jt))
            | Some (e1, e2) ->
              begin match Jdg.alpha_equal_eq_ty ~loc Jdg.ty_ty (Jdg.typeof e1) with
                | None -> Opt.lift Runtime.(error ~loc (InvalidAsEquality jt))
                | Some _ ->
                  begin match Jdg.alpha_equal_eq_ty ~loc t (Jdg.is_ty ~loc e1) with
                    | None -> Opt.lift Runtime.(error ~loc (InvalidAsEquality jt))
                    | Some _ ->
                      begin match as_eq_alpha (Jdg.is_ty ~loc e2) with
                        | None ->
                          Runtime.(error ~loc (InvalidAsEquality jt))

                        | Some (e1,e2) ->
                          let eq = Jdg.is_type_equality ~loc (Jdg.reflect ~loc juser) in
                          Opt.return (eq, e1, e2)
                      end
                  end
              end
          end
      end

let as_prod_alpha t =
  match Jdg.shape_ty t with
    | Jdg.Prod (a, b) -> Some (a, b)
    | _ -> None

let as_prod ~loc t =
  match as_prod_alpha t with
    | Some (a, b) -> Opt.return (Jdg.reflexivity_ty t, a, b)
    | None ->
      Predefined.operation_as_prod ~loc t >!=
      begin function
        | None ->
          Opt.fail
        | Some juser ->
          let jt = Jdg.typeof juser in
          begin match as_eq_alpha jt with
            | None ->
               Opt.lift Runtime.(error ~loc (InvalidAsProduct jt))
            | Some (e1, e2) ->
              begin match Jdg.alpha_equal_eq_ty ~loc Jdg.ty_ty (Jdg.typeof e1) with
                | None -> Opt.lift Runtime.(error ~loc (InvalidAsProduct jt))
                | Some _ ->
                  begin match Jdg.alpha_equal_eq_ty ~loc t (Jdg.is_ty ~loc e1) with
                    | None -> Opt.lift Runtime.(error ~loc (InvalidAsProduct jt))
                    | Some _ ->
                      begin match as_prod_alpha (Jdg.is_ty ~loc e2) with
                        | None ->
                          Runtime.(error ~loc (InvalidAsProduct jt))

                        | Some (a, b) ->
                          let eq = Jdg.is_type_equality ~loc (Jdg.reflect ~loc juser) in
                          Opt.return (eq, a, b)
                      end
                  end
              end
          end
      end

end

(** Expose without the monad stuff *)

let equal ~loc j1 j2 = Opt.run (Internals.equal ~loc j1 j2)

let equal_ty ~loc j1 j2 = Opt.run (Internals.equal_ty ~loc j1 j2)

let coerce ~loc je jt = Opt.run (Internals.coerce ~loc je jt)

let coerce_fun ~loc je = Opt.run (Internals.coerce_fun ~loc je)

let as_eq ~loc j = Opt.run (Internals.as_eq ~loc j)

let as_prod ~loc j = Opt.run (Internals.as_prod ~loc j)
