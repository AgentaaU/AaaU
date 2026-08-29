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
  creator:Auth.user_info ->
  agent_user:string ->
  editor_socket_path:string ->
  program:string ->
  args:string list ->
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

val authorize_editor_provider : creator_uid:int -> Auth.user_info -> bool
val authorize_editor_request :
  agent_uid:int -> agent_session_id:int -> Auth.user_info -> peer_session_id:int -> bool
val editor_request_authorized : t -> Auth.user_info -> peer_session_id:int -> bool

val register_editor_provider :
  t -> socket:Lwt_unix.file_descr -> user_info:Auth.user_info ->
  (unit Lwt.t, string) result Lwt.t
(** Register the creator's dedicated provider socket. The returned promise is
    resolved when this provider is replaced or the session stops. *)

val forward_editor_request :
  t -> user_info:Auth.user_info -> peer_session_id:int -> string ->
  Editor_protocol.response Lwt.t
(** Submit one request from the configured agent account. Requests are
    serialized and failures are returned without affecting the PTY. *)

val compact_output_buffer : Buffer.t -> last_sent_pos:int -> int
(** Compact the output history buffer when it grows too large.
    Returns the adjusted last_sent_pos for the compacted buffer. *)

module Lwt_queue : sig
  type 'a t
  val create : unit -> 'a t
  val push : 'a -> 'a t -> unit Lwt.t
  val pop : 'a t -> 'a Lwt.t
end
