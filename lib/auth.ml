(** Authentication implementation *)

external get_peer_credentials : Unix.file_descr -> int * int
  = "aaau_get_peer_credentials"

external get_peer_session_id : Unix.file_descr -> int
  = "aaau_get_peer_session_id"

type permission =
  | ReadOnly
  | Interactive
  | Admin

type user_info = {
  username : string;
  uid : int;
  gid : int;
  permission : permission;
}

let string_of_permission = function
  | ReadOnly -> "readonly"
  | Interactive -> "interactive"
  | Admin -> "admin"

let permission_of_string = function
  | "readonly" -> Some ReadOnly
  | "interactive" -> Some Interactive
  | "admin" -> Some Admin
  | _ -> None

let permission_for_uid uid = if uid = 0 then Admin else Interactive

let user_in_group ~username ~user_entry group_entry =
  user_entry.Unix.pw_gid = group_entry.Unix.gr_gid
  || Array.exists (( = ) username) group_entry.Unix.gr_mem

let authenticate ~peer_uid ~peer_gid ~shared_group =
  try
    (* Get user information *)
    let user_entry = Unix.getpwuid peer_uid in
    let username = user_entry.Unix.pw_name in

    (* Root is the only administrator. Other peers must be human members of
       the explicitly configured control group. *)
    let shared_group_entry = Unix.getgrnam shared_group in
    let in_shared_group =
      peer_gid = shared_group_entry.Unix.gr_gid
      || user_in_group ~username ~user_entry shared_group_entry
    in

    if peer_uid <> 0 && not in_shared_group then
      Error (Printf.sprintf "User %s not in shared group %s" username shared_group)
    else
      let permission = permission_for_uid peer_uid in

      Ok {
        username;
        uid = peer_uid;
        gid = peer_gid;
        permission;
      }

  with
  | Not_found -> Error "User or group not found"
  | e -> Error (Printexc.to_string e)

let authenticate_socket socket ~shared_group =
  try
    let peer_uid, peer_gid = get_peer_credentials socket in
    authenticate ~peer_uid ~peer_gid ~shared_group
  with
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | e -> Error (Printexc.to_string e)

let authenticate_agent_socket socket ~agent_user =
  try
    let peer_uid, peer_gid = get_peer_credentials socket in
    let account = Unix.getpwnam agent_user in
    if peer_uid <> account.Unix.pw_uid then
      Error "Editor request socket is restricted to the configured agent account"
    else
      let peer_session_id = get_peer_session_id socket in
      Ok ({ username = account.Unix.pw_name; uid = peer_uid; gid = peer_gid; permission = ReadOnly },
          peer_session_id)
  with
  | Not_found -> Error "Configured agent account not found"
  | Unix.Unix_error (err, fn, arg) -> Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message err))
  | e -> Error (Printexc.to_string e)

let check_permission perm ~action =
  match perm, action with
  | Admin, _ -> true
  | Interactive, ("input" | "resize" | "ping") -> true
  | Interactive, _ -> false
  | ReadOnly, "read" -> true
  | ReadOnly, _ -> false
