(* $Id: perso.mli,v 5.7 2007-03-30 18:57:19 ddr Exp $ *)
(* Copyright (c) 1998-2007 INRIA *)

open Gwdb
open Config

type generation_person =
    GP_person of Sosa.t * iper * ifam option
  | GP_same of Sosa.t * Sosa.t * iper
  | GP_interv of (Sosa.t * Sosa.t * (Sosa.t * Sosa.t) option) option
  | GP_missing of Sosa.t * iper

val string_of_marriage_text : config -> base -> family -> Adef.safe_string

val interp_templ : ?no_headers:bool -> string -> config -> base -> person -> unit
val interp_templ_with_menu :
  (bool -> unit) -> string -> config -> base -> person -> unit
val interp_notempl_with_menu :
  (bool -> unit) -> string -> config -> base -> person -> unit

(** Displays the HTML page of a person *)
val print : ?no_headers:bool -> config -> base -> person -> unit

(** Displays the ascendants of the selected person *)
val print_ascend : config -> base -> person -> unit

(** Displays links to pages associated to the person *)
val print_what_links : config -> base -> person -> unit

val links_to_ind
  : Config.config
  -> Gwdb.base
  -> ((iper, ifam) Def.NLDB.page * ('a * ((string * string * int) * 'b) list)) list
  -> string * string * int
  -> (iper, ifam) Def.NLDB.page list

(** Construts from the giving person sosa table strored in the cache. Sosa table contains association
    {i person_id -> sosa number} for each person in the base.
    Person has sosa [Sosa.one] and his ancestors have sosa > [Sosa.one].
    For non ancestor person sosa number is set to [Sosa.zero]. *)
val build_sosa_tree_ht : config -> base -> person -> unit

(** Extract referenced person from environement and constructs for him sosa table wiht [build_sosa_tree_ht]. *)
val build_sosa_ht : config -> base -> unit


val get_sosa_person : person -> Sosa.t
val get_single_sosa : config -> base -> person -> Sosa.t
val print_sosa : config -> base -> person -> bool -> unit

val get_linked_page : config -> base -> person -> string -> Adef.safe_string
val get_birth_text : config -> person -> bool -> Adef.safe_string
val get_baptism_text : config -> person -> bool -> Adef.safe_string
val get_death_text : config -> person -> bool -> Adef.safe_string
val get_burial_text : config -> person -> bool -> Adef.safe_string
val get_cremation_text : config -> person -> bool -> Adef.safe_string
val get_marriage_date_text : config -> family -> bool -> Adef.safe_string

val linked_page_text
  : Config.config
  -> Gwdb.base
  -> Gwdb.person
  -> string
  -> 'a
  -> Adef.safe_string
  -> (iper, ifam) Def.NLDB.page * ('b * ('a * Def.NLDB.ind) list)
  -> Adef.safe_string

val max_ancestor_level : config -> base -> iper -> int -> int

val string_of_died : config -> person -> bool -> Adef.safe_string

val string_of_parent_age : config -> base -> person * bool -> (family -> iper) -> Adef.safe_string

val string_of_image_url : config -> base -> person * bool -> bool -> Adef.escaped_string

val round_2_dec : float -> float

val has_children : base -> person -> bool

val string_of_image_size : config -> base -> person * bool -> string
val string_of_image_medium_size : config -> base -> person * bool -> string
val string_of_image_small_size : config -> base -> person * bool -> string

val get_link : generation_person list -> Util.IperSet.elt -> generation_person option

(**)

val infinite : int
val limit_desc : config -> int
val make_desc_level_table
  : config
  -> base
  -> int
  -> person
  -> (Util.IperSet.elt, int) Gwdb.Marker.t * (ifam, int) Gwdb.Marker.t

val default_max_cousin_lev : int

type dup =
    DupFam of ifam * ifam
  | DupInd of iper * iper
  | NoDup

type excl_dup = (iper * iper) list * (ifam * ifam) list

val excluded_possible_duplications : config -> excl_dup
val first_possible_duplication : base -> iper -> excl_dup -> dup


(* Ajout pour l'API *)
val nobility_titles_list :
  config -> base -> person ->
    (int * istr Def.gen_title_name * istr * istr list *
       (Adef.date option * Adef.date option) list)
      list

val has_history : config -> base -> person -> bool -> bool
val has_possible_duplications : config -> base -> person -> bool

(** Optionnal [link] argument is passed to {!val:DateDisplay.string_of_ondate} *)
val string_of_title
  : ?safe:bool
  -> ?link:bool
  -> config
  -> base
  -> Adef.safe_string
  -> person
  -> int * istr Def.gen_title_name * istr * istr list * (Def.date option * Def.date option) list
  -> Adef.safe_string

type event_name =
    Pevent of istr Def.gen_pers_event_name
  | Fevent of istr Def.gen_fam_event_name

val events_list :
  config -> base -> person ->
    (event_name * Def.cdate * istr * istr * istr *
       (iper * Def.witness_kind) array * iper option)
      list
