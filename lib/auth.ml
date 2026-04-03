(** Authentication implementation *)

external get_peer_credentials : Unix.file_descr -> int * int
  = "aaau_get_peer_credentials"

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

let user_in_group ~username ~user_entry group_entry =
  user_entry.Unix.pw_gid = group_entry.Unix.gr_gid
  || Array.exists (( = ) username) group_entry.Unix.gr_mem

let authenticate ~peer_uid ~peer_gid ~shared_group =
  try
    (* Get user information *)
    let user_entry = Unix.getpwuid peer_uid in
    let username = user_entry.Unix.pw_name in

    (* Check if in shared group *)
    let shared_group_entry = Unix.getgrnam shared_group in
    let in_shared_group =
      peer_gid = shared_group_entry.Unix.gr_gid
      || user_in_group ~username ~user_entry shared_group_entry
    in

    if not in_shared_group then
      Error (Printf.sprintf "User %s not in shared group %s" username shared_group)
    else
      (* Simple permission policy: system users with uid < 1000 get admin *)
      (* In practice, should use config file or database *)
      let permission =
        if peer_uid < 1000 then Admin
        else Interactive
      in

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

let check_permission perm ~action =
  match perm, action with
  | Admin, _ -> true
  | Interactive, ("input" | "resize" | "ping") -> true
  | Interactive, _ -> false
  | ReadOnly, "read" -> true
  | ReadOnly, _ -> false
