(** Lookup an external value, if any. *)
val lookup : string -> (Location.t -> Runtime.value Runtime.comp) option

val lookup_ty : string -> Mlty.ty_schema option

