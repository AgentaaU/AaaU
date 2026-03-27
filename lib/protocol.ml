(** Protocol implementation - simple text protocol *)

type client_message =
  | Input of string
  | Resize of { rows : int; cols : int }
  | Ping
  | GetStatus
  | ForceKill
  | Unknown of string

type server_message =
  | Output of string
  | Pong
  | Status of Yojson.Safe.t
  | Error of string
  | Control of string

let control_char = '\x01'

let encode_client = function
  | Input s -> s
  | Resize { rows; cols } ->
    Printf.sprintf "%cRESIZE:%d,%d" control_char rows cols
  | Ping -> Printf.sprintf "%cPING" control_char
  | GetStatus -> Printf.sprintf "%cGET_STATUS" control_char
  | ForceKill -> Printf.sprintf "%cFORCE_KILL" control_char
  | Unknown s -> s

let decode_client s =
  if String.length s > 0 && s.[0] = control_char then
    let payload = String.sub s 1 (String.length s - 1) in
    match String.split_on_char ':' payload with
    | ["RESIZE"; size] ->
      (match String.split_on_char ',' size with
       | [r; c] ->
         (try Resize { rows = int_of_string r; cols = int_of_string c }
          with _ -> Unknown s)
       | _ -> Unknown s)
    | ["PING"] -> Ping
    | ["GET_STATUS"] -> GetStatus
    | ["FORCE_KILL"] -> ForceKill
    | _ -> Unknown s
  else
    Input s

let encode_server = function
  | Output s -> s
  | Pong -> Printf.sprintf "%cPONG" control_char
  | Status json ->
    Printf.sprintf "%cSTATUS:%s" control_char (Yojson.Safe.to_string json)
  | Error msg -> Printf.sprintf "%cERROR:%s" control_char msg
  | Control msg -> Printf.sprintf "%cCONTROL:%s" control_char msg

let decode_server s =
  if String.length s > 0 && s.[0] = control_char then
    let payload = String.sub s 1 (String.length s - 1) in
    match String.split_on_char ':' payload with
    | ["PONG"] -> Pong
    | ["STATUS"; json] ->
      (try Status (Yojson.Safe.from_string json) with _ -> Control payload)
    | ["ERROR"; msg] -> Error msg
    | ["CONTROL"; msg] -> Control msg
    | _ -> Control payload
  else
    Output s

let is_control s =
  String.length s > 0 && s.[0] = control_char

(* Frame a message with 4-byte length prefix (big-endian) *)
let frame_message msg =
  let len = String.length msg in
  let framed = Bytes.create (4 + len) in
  Bytes.set_int32_be framed 0 (Int32.of_int len);
  Bytes.blit_string msg 0 framed 4 len;
  Bytes.unsafe_to_string framed

(* Try to parse a framed message. Returns Some (message, remaining) if complete *)
let try_parse_framed buf =
  if String.length buf < 4 then
    None
  else
    let len = Int32.to_int (Bytes.get_int32_be (Bytes.unsafe_of_string buf) 0) in
    if len < 0 || len > 1000000 then
      (* Invalid length - skip this buffer *)
      None
    else if String.length buf >= 4 + len then
      let msg = String.sub buf 4 len in
      let remaining =
        if String.length buf > 4 + len then
          String.sub buf (4 + len) (String.length buf - 4 - len)
        else
          ""
      in
      Some (msg, remaining)
    else
      (* Incomplete message *)
      None
