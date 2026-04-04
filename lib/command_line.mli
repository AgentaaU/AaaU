(** Shell-style command line parsing helpers. *)

val split_command : string -> (string * string list, string) result
(** [split_command input] tokenizes a user-provided command string into a
    program and its arguments.

    Supports whitespace separation, single quotes, double quotes, and
    backslash escaping. Returns an error for empty input or unterminated
    quotes. *)

val expand_program_alias : string -> string option
(** [expand_program_alias alias] expands a supported client shorthand into
    its full [--program] command string. Returns [None] for unknown aliases. *)
