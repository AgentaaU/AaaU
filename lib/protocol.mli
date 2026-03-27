(** Client-server communication protocol *)

type client_message =
  | Input of string           (** Normal input *)
  | Resize of { rows : int; cols : int }  (** Terminal resize *)
  | Ping                      (** Heartbeat *)
  | GetStatus                 (** Query status *)
  | ForceKill                 (** Force kill (admin) *)
  | Unknown of string

type server_message =
  | Output of string          (** PTY output *)
  | Pong                      (** Heartbeat response *)
  | Status of Yojson.Safe.t   (** Session status *)
  | Error of string           (** Error message *)
  | Control of string         (** Control notification *)

val encode_client : client_message -> string
(** Encode client message *)

val decode_client : string -> client_message
(** Decode client message *)

val encode_server : server_message -> string
(** Encode server message *)

val decode_server : string -> server_message
(** Decode server message *)

val is_control : string -> bool
(** Check if it's a control message (starts with \x01) *)

val frame_message : string -> string
(** Add length framing to a message: 4-byte length prefix + message *)

val try_parse_framed : string -> (string * string) option
(** Try to parse a framed message. Returns Some (message, remaining) if a complete message is found, None otherwise. *)
