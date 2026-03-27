(** Authentication implementation *)

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

let authenticate ~peer_uid ~peer_gid ~shared_group =
  try
    (* Get user information *)
    let user_entry = Unix.getpwuid peer_uid in
    let username = user_entry.Unix.pw_name in

    (* Check if in shared group *)
    let shared_gid = (Unix.getgrnam shared_group).Unix.gr_gid in

    let in_shared_group =
      peer_gid = shared_gid ||
      (* Get user's group list *)
      try
        (* Get all groups of current process *)
        let groups = Unix.getgroups () in
        Array.mem shared_gid groups
      with _ -> false
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

let check_permission perm ~action =
  match perm, action with
  | Admin, _ -> true
  | Interactive, ("input" | "resize" | "ping") -> true
  | Interactive, _ -> false
  | ReadOnly, "read" -> true
  | ReadOnly, _ -> false
