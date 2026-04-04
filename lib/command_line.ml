(** Shell-style command line parsing helpers. *)

let split_command input =
  let len = String.length input in
  let token = Buffer.create len in
  let tokens = ref [] in
  let push_token () =
    if Buffer.length token > 0 then begin
      tokens := Buffer.contents token :: !tokens;
      Buffer.clear token
    end
  in
  let rec skip_ws i =
    if i < len then
      match input.[i] with
      | ' ' | '\t' | '\n' | '\r' -> skip_ws (i + 1)
      | _ -> parse_token i
    else
      finish ()
  and parse_token i =
    if i >= len then begin
      push_token ();
      finish ()
    end else
      match input.[i] with
      | ' ' | '\t' | '\n' | '\r' ->
        push_token ();
        skip_ws (i + 1)
      | '\'' -> parse_single_quote (i + 1)
      | '"' -> parse_double_quote (i + 1)
      | '\\' ->
        if i + 1 >= len then
          Error "Trailing backslash in program string"
        else begin
          Buffer.add_char token input.[i + 1];
          parse_token (i + 2)
        end
      | c ->
        Buffer.add_char token c;
        parse_token (i + 1)
  and parse_single_quote i =
    if i >= len then
      Error "Unterminated single quote in program string"
    else if input.[i] = '\'' then
      parse_token (i + 1)
    else begin
      Buffer.add_char token input.[i];
      parse_single_quote (i + 1)
    end
  and parse_double_quote i =
    if i >= len then
      Error "Unterminated double quote in program string"
    else
      match input.[i] with
      | '"' -> parse_token (i + 1)
      | '\\' ->
        if i + 1 >= len then
          Error "Trailing backslash in quoted program string"
        else begin
          Buffer.add_char token input.[i + 1];
          parse_double_quote (i + 2)
        end
      | c ->
        Buffer.add_char token c;
        parse_double_quote (i + 1)
  and finish () =
    match List.rev !tokens with
    | [] -> Error "Program string is empty"
    | program :: args -> Ok (program, args)
  in
  skip_ws 0

let expand_program_alias = function
  | "codex" -> Some "codex --dangerously-bypass-approvals-and-sandbox"
  | "claude" -> Some "claude --dangerously-skip-permissions"
  | _ -> None
