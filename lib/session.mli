(** Single Agent session management *)

type t

type client = {
  socket : Lwt_unix.file_descr;
  addr : string;
  user_info : Auth.user_info;
  connected_at : float;
  mutable last_activity : float;
}

val create :
  session_id:string ->
  creator:string ->
  agent_user:string ->
  ?program:string ->
  ?args:string list ->
  rows:int ->
  cols:int ->
  audit:Audit.t ->
  (t, string) result Lwt.t
(** Create new session, start agent with specified terminal size.
    Default program is /bin/bash. Use ~program:"kimi-cli" to run kimi-cli as agent. *)

val add_client :
  t ->
  socket:Lwt_unix.file_descr ->
  addr:string ->
  user_info:Auth.user_info ->
  (client, string) result Lwt.t
(** Add client to session *)

val remove_client : t -> client -> unit Lwt.t
(** Remove client *)

val handle_client_input :
  t ->
  client:client ->
  data:string ->
  unit Lwt.t
(** Handle client input *)

val is_alive : t -> bool
(** Check if agent is alive *)

val shutdown : t -> unit Lwt.t
(** Close session *)

val get_id : t -> string
val get_clients : t -> client list
val get_agent_pid : t -> int option

module Lwt_queue : sig
  type 'a t
  val create : unit -> 'a t
  val push : 'a -> 'a t -> unit Lwt.t
  val pop : 'a t -> 'a Lwt.t
end
