(** Authentication and permission management *)

type permission =
  | ReadOnly      (** Read-only viewing *)
  | Interactive   (** Can input commands *)
  | Admin         (** Can manage sessions *)

type user_info = {
  username : string;
  uid : int;
  gid : int;
  permission : permission;
}

val authenticate :
  peer_uid:int ->
  peer_gid:int ->
  shared_group:string ->
  (user_info, string) result
(** Authenticate user based on Unix socket credentials *)

val authenticate_socket :
  Unix.file_descr ->
  shared_group:string ->
  (user_info, string) result
(** Authenticate a connected Unix domain socket peer *)

val authenticate_agent_socket :
  Unix.file_descr -> agent_user:string -> ((user_info * int), string) result
(** Authenticate exactly the configured agent account on the isolated editor
    request socket and return its Linux kernel session ID. *)

val check_permission : permission -> action:string -> bool
(** Check if permission allows an action *)

val string_of_permission : permission -> string
val permission_of_string : string -> permission option
val permission_for_uid : int -> permission
