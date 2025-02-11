(* Copyright (c) 1998-2007 INRIA *)

open Config
open Def
open Gwdb
open TemplAst
open Util

let max_im_wid = 240
let round_2_dec x = floor (x *. 100.0 +. 0.5) /. 100.0

let has_children base u =
  Array.exists
    (fun ifam ->
       let des = foi base ifam in Array.length (get_children des) > 0)
    (get_family u)

let string_of_marriage_text conf base fam =
  let marriage = Adef.od_of_cdate (get_marriage fam) in
  let marriage_place = sou base (get_marriage_place fam) in
  let s =
    match marriage with
    | Some d -> " " ^<^ DateDisplay.string_of_ondate conf d
    | _ -> Adef.safe ""
  in
  match marriage_place with
  | "" -> s
  | _ -> s ^^^ ", " ^<^ Util.safe_html (string_with_macros conf [] marriage_place) ^>^ ","

let string_of_title ?(safe = false) ?(link = true) conf base (and_txt : Adef.safe_string) p (nth, name, title, places, dates) =
  let safe_html = if not safe then Util.safe_html else Adef.safe in
  let escape_html = if not safe then Util.escape_html else Adef.escaped in
  let (tit, est) = sou base title, sou base (List.hd places) in
  let acc = safe_html (tit ^ " " ^ est) in
  let href place s =
    if link then
      let href =
        "m=TT&sm=S&t="
        ^<^ Mutil.encode (sou base title)
        ^^^ "&p="
        ^<^ Mutil.encode (sou base place)
      in
      geneweb_link conf (href : Adef.encoded_string :> Adef.escaped_string) s
    else s
  in
  let acc = href (List.hd places) acc in
  let rec loop acc places =
    let acc = match places with
      | [] -> acc
      | [_] -> acc ^^^ " " ^<^ and_txt ^^^ (Adef.safe " ")
      | _ -> acc ^>^ ", "
    in
    match places with
    | place :: places ->
      let est = safe_html (sou base place) in
      let acc = acc ^^^ href place est in
      loop acc places
    | _ -> acc
  in
  let acc = loop acc (List.tl places) in
  let paren =
    match nth, dates, name with
    | n, _, _ when n > 0 -> true
    | _, _, Tname _ -> true
    | _, (Some _, _) :: _, _ -> authorized_age conf base p
    | _ -> false
  in
  let acc = if paren then acc ^>^ " (" else acc in
  let first = nth <= 0 in
  let acc =
    if first then acc
    else acc ^>^ (if nth >= 100 then string_of_int nth else transl_nth conf "nth" nth)
  in
  let acc, first =
    match name with
    | Tname n ->
      let acc = if not first then acc ^>^ " ," else acc in
      ( acc ^^^ (sou base n |> escape_html :> Adef.safe_string)
      , false )
    | _ -> acc, first
  in
  let acc =
    if authorized_age conf base p && dates <> [None, None] then
      fst @@ List.fold_left begin fun (acc, first) (date_start, date_end) ->
        let acc = if not first then acc ^>^ ", " else acc in
        let acc = match date_start with
          | Some d -> acc ^^^ DateDisplay.string_of_date conf d
          | None -> acc
        in
        let acc = match date_end with
          | Some (Dgreg (d, _)) ->
            if d.month <> 0 then acc ^>^ " - "
            else acc ^>^ "-"
          | Some (Dtext _) -> acc ^>^ " - "
          | _ -> acc
        in
        let acc = match date_end with
          | Some d -> acc ^^^ DateDisplay.string_of_date conf d
          | None -> acc
        in
        (acc, false)
      end (acc, first) dates
    else acc
  in
  if paren then acc ^>^ ")" else acc

let name_equiv n1 n2 =
  Futil.eq_title_names eq_istr n1 n2 || n1 = Tmain && n2 = Tnone ||
  n1 = Tnone && n2 = Tmain

let nobility_titles_list conf base p =
  let titles =
    List.fold_right
      (fun t l ->
         let t_date_start = Adef.od_of_cdate t.t_date_start in
         let t_date_end = Adef.od_of_cdate t.t_date_end in
         match l with
           (nth, name, title, place, dates) :: rl
           when
             not conf.is_rtl && nth = t.t_nth && name_equiv name t.t_name &&
             eq_istr title t.t_ident && eq_istr place t.t_place ->
             (nth, name, title, place, (t_date_start, t_date_end) :: dates) ::
             rl
         | _ ->
             (t.t_nth, t.t_name, t.t_ident, t.t_place,
              [t_date_start, t_date_end]) ::
             l)
      (Util.nobtit conf base p) []
  in
  List.fold_right
    (fun (t_nth, t_name, t_ident, t_place, t_dates) l ->
       match l with
         (nth, name, title, places, dates) :: rl
         when
           not conf.is_rtl && nth = t_nth && name_equiv name t_name &&
           eq_istr title t_ident && dates = t_dates ->
           (nth, name, title, t_place :: places, dates) :: rl
       | _ -> (t_nth, t_name, t_ident, [t_place], t_dates) :: l)
    titles []

(* Optimisation de find_sosa_aux :                                           *)
(* - ajout d'un cache pour conserver les descendants du sosa que l'on calcul *)
(* - on sauvegarde la dernière génération où l'on a arrêté le calcul pour    *)
(*   ne pas reprendre le calcul depuis la racine                             *)

(* Type pour ne pas créer à chaque fois un tableau tstab et mark *)
type sosa_t =
  { tstab : (iper, int) Gwdb.Marker.t;
    mark : (iper, bool) Gwdb.Marker.t;
    mutable last_zil : (iper * Sosa.t) list;
    sosa_ht : (iper, (Sosa.t * Gwdb.person) option) Hashtbl.t }

let init_sosa_t conf base sosa_ref =
  try
    let tstab = Util.create_topological_sort conf base in
    let mark = Gwdb.iper_marker (Gwdb.ipers base) false in
    let last_zil = [get_iper sosa_ref, Sosa.one] in
    let sosa_ht = Hashtbl.create 5003 in
    Hashtbl.add sosa_ht (get_iper sosa_ref) (Some (Sosa.one, sosa_ref)) ;
    Some {tstab = tstab; mark = mark; last_zil = last_zil; sosa_ht = sosa_ht}
  with Consang.TopologicalSortError _ -> None

let find_sosa_aux conf base a p t_sosa =
  let cache = ref [] in
  let has_ignore = ref false in
  let ht_add ht k v new_sosa =
    match try Hashtbl.find ht k with Not_found -> v with
      Some (z, _) -> if not (Sosa.gt new_sosa z) then Hashtbl.replace ht k v
    | _ -> ()
  in
  let rec gene_find =
    function
      [] -> Left []
    | (ip, z) :: zil ->
        let _ = cache := (ip, z) :: !cache in
        if ip = get_iper a then Right z
        else if Gwdb.Marker.get t_sosa.mark ip then gene_find zil
        else
          begin
            Gwdb.Marker.set t_sosa.mark ip true;
            if Gwdb.Marker.get t_sosa.tstab (get_iper a)
               <= Gwdb.Marker.get t_sosa.tstab ip
            then
              let _ = has_ignore := true in gene_find zil
            else
              let asc = pget conf base ip in
              match get_parents asc with
                Some ifam ->
                  let cpl = foi base ifam in
                  let z = Sosa.twice z in
                  begin match gene_find zil with
                    Left zil ->
                      Left
                        ((get_father cpl, z) ::
                         (get_mother cpl, Sosa.inc z 1) :: zil)
                  | Right z -> Right z
                  end
              | None -> gene_find zil
          end
  in
  let rec find zil =
    match
      try gene_find zil with
        Invalid_argument msg when msg = "index out of bounds" ->
          Update.delete_topological_sort conf base; Left []
    with
      Left [] ->
        let _ =
          List.iter
            (fun (ip, _) -> Gwdb.Marker.set t_sosa.mark ip false)
            !cache
        in
        None
    | Left zil ->
        let _ =
          if !has_ignore then ()
          else
            begin
              List.iter
                (fun (ip, z) -> ht_add t_sosa.sosa_ht ip (Some (z, p)) z) zil;
              t_sosa.last_zil <- zil
            end
        in
        find zil
    | Right z ->
        let _ =
          List.iter
            (fun (ip, _) -> Gwdb.Marker.set t_sosa.mark ip false)
            !cache
        in
        Some (z, p)
  in
  find t_sosa.last_zil

let find_sosa conf base a sosa_ref t_sosa =
  match sosa_ref with
    Some p ->
      if get_iper a = get_iper p then Some (Sosa.one, p)
      else
        let u = pget conf base (get_iper a) in
        if has_children base u then
          try Hashtbl.find t_sosa.sosa_ht (get_iper a) with
            Not_found -> find_sosa_aux conf base a p t_sosa
        else None
  | None -> None

(* [Type]: (iper, Sosa.t) Hashtbl.t *)
let sosa_ht = Hashtbl.create 5003

(* ************************************************************************ *)
(*  [Fonc] build_sosa_tree_ht : config -> base -> person -> unit            *)
(** [Description] : Construit à partir d'une personne la base, la
      liste de tous ses ancêtres directs et la stocke dans une hashtbl. La
      clé de la table est l'iper de la personne et on lui associe son numéro
      de sosa. Les sosa multiples ne sont représentés qu'une seule fois par
      leur plus petit numéro sosa.
    [Args] :
      - conf : configuration de la base
      - base : base de donnée
    [Retour] :
      - unit
    [Rem] : Exporté en clair hors de ce module.                             *)
(* ************************************************************************ *)
let build_sosa_tree_ht conf base person =
  let () = load_ascends_array base in
  let () = load_couples_array base in
  let nb_persons = nb_of_persons base in
  let mark = Gwdb.iper_marker (Gwdb.ipers base) false in
  (* Tableau qui va socker au fur et à mesure les ancêtres du person. *)
  (* Attention, on créé un tableau de la longueur de la base + 1 car on *)
  (* commence à l'indice 1 !                                            *)
  let sosa_accu =
    Array.make (nb_persons + 1) (Sosa.zero, dummy_iper)
  in
  let () = Array.set sosa_accu 1 (Sosa.one, get_iper person) in
  let rec loop i len =
    if i > nb_persons then ()
    else
      let (sosa_num, ip) = Array.get sosa_accu i in
      (* Si la personne courante n'a pas de numéro de sosa, alors il n'y *)
      (* a plus d'ancêtres car ils ont été ajoutés par ordre croissant.  *)
      if Sosa.eq sosa_num Sosa.zero then ()
      else
        begin
          Hashtbl.add sosa_ht ip sosa_num;
          let asc = pget conf base ip in
          (* Ajoute les nouveaux ascendants au tableau des ancêtres. *)
          match get_parents asc with
            Some ifam ->
              let cpl = foi base ifam in
              let z = Sosa.twice sosa_num in
              let len =
                if not @@ Gwdb.Marker.get mark (get_father cpl) then
                  begin
                    Array.set sosa_accu (len + 1) (z, get_father cpl);
                    Gwdb.Marker.set mark (get_father cpl) true;
                    len + 1
                  end
                else len
              in
              let len =
                if not @@ Gwdb.Marker.get mark (get_mother cpl) then
                  begin
                    Array.set sosa_accu (len + 1) (Sosa.inc z 1, get_mother cpl);
                    Gwdb.Marker.set mark (get_mother cpl) true ;
                    len + 1
                  end
                else len
              in
              loop (i + 1) len
          | None -> loop (i + 1) len
        end
  in
  loop 1 1

(* ************************************************************************ *)
(*  [Fonc] build_sosa_ht : config -> base -> unit                           *)
(** [Description] : Fait appel à la construction de la
      liste de tous les ancêtres directs de la souche de l'arbre
    [Args] :
      - conf : configuration de la base
      - base : base de donnée
    [Retour] :
      - unit
    [Rem] : Exporté en clair hors de ce module.                             *)
(* ************************************************************************ *)
let build_sosa_ht conf base =
  match Util.find_sosa_ref conf base with
    Some sosa_ref -> build_sosa_tree_ht conf base sosa_ref
  | None -> ()

(* ******************************************************************** *)
(*  [Fonc] next_sosa : Sosa.t -> Sosa.t               *)
(** [Description] : Recherche le sosa suivant
    [Args] :
      - s    : sosa
    [Retour] :
      - Sosa.t : retourne Sosa.zero s'il n'y a pas de sosa suivant      *)
(* ******************************************************************** *)
let next_sosa s =
  (* La clé de la table est l'iper de la personne et on lui associe son numéro
    de sosa. On inverse pour trier sur les sosa *)
  let sosa_list = Hashtbl.fold (fun k v acc -> (v, k) :: acc) sosa_ht [] in
  let sosa_list = List.sort (fun (s1, _) (s2, _) -> Sosa.compare s1 s2) sosa_list in
  let rec find_n x lst = match lst with
    | [] -> (Sosa.zero, dummy_iper)
    | (so, _) :: tl ->
        if (Sosa.eq so x) then
          if tl = [] then (Sosa.zero, dummy_iper) else List.hd tl
        else find_n x tl
  in
  let (so, ip) = find_n s sosa_list in
  (so, ip)

let prev_sosa s =
  let sosa_list = Hashtbl.fold (fun k v acc -> (v, k) :: acc) sosa_ht [] in
  let sosa_list = List.sort (fun (s1, _) (s2, _) -> Sosa.compare s1 s2) sosa_list in
  let sosa_list = List.rev sosa_list in
  let rec find_n x lst = match lst with
    | [] -> (Sosa.zero, dummy_iper)
    | (so, _) :: tl ->
        if (Sosa.eq so x) then
          if tl = [] then (Sosa.zero, dummy_iper) else List.hd tl
        else find_n x tl
  in
  let (so, ip) = find_n s sosa_list in
  (so, ip)



(* ******************************************************************** *)
(*  [Fonc] get_sosa_person : config -> person -> Sosa.t          *)
(** [Description] : Recherche si la personne passée en argument a un
                    numéro de sosa.
    [Args] :
      - p    : personne dont on cherche si elle a un numéro sosa
    [Retour] :
      - Sosa.t : retourne Sosa.zero si la personne n'a pas de numéro de
                sosa, ou retourne son numéro de sosa sinon
    [Rem] : Exporté en clair hors de ce module.                         *)
(* ******************************************************************** *)
let get_sosa_person p =
  try Hashtbl.find sosa_ht (get_iper p) with Not_found -> Sosa.zero

(* ********************************************************************** *)
(*  [Fonc] has_history : config -> string -> bool                         *)
(** [Description] : Indique si l'individu a été modifiée.
    [Args] :
      - conf   : configuration de la base
      - base   : arbre
      - p      : person
      - p_auth : indique si l'utilisateur est authentifié
    [Retour] : Vrai si la personne a été modifiée, Faux sinon.
    [Rem] : Exporté en clair hors de ce module.                           *)
(* ********************************************************************** *)
let has_history conf base p p_auth =
  let fn = sou base (get_first_name p) in
  let sn = sou base (get_surname p) in
  let occ = get_occ p in
  let person_file = HistoryDiff.history_file fn sn occ in
  p_auth && Sys.file_exists (HistoryDiff.history_path conf person_file)

(* ******************************************************************** *)
(*  [Fonc] get_single_sosa : config -> base -> person -> Sosa.t          *)
(** [Description] : Recherche si la personne passée en argument a un
                    numéro de sosa.
    [Args] :
    - conf : configuration de la base
    - base : base de donnée
    - p    : personne dont on cherche si elle a un numéro sosa
      [Retour] :
    - Sosa.t : retourne Sosa.zero si la personne n'a pas de numéro de
                sosa, ou retourne son numéro de sosa sinon
      [Rem] : Exporté en clair hors de ce module.                         *)
(* ******************************************************************** *)
let get_single_sosa conf base p =
  match Util.find_sosa_ref conf base with
  | None -> Sosa.zero
  | Some p_sosa as sosa_ref ->
    match init_sosa_t conf base p_sosa with
    | None -> Sosa.zero
    | Some t_sosa ->
      match find_sosa conf base p sosa_ref t_sosa with
      | Some (z, _) -> z
      | None -> Sosa.zero

(* ************************************************************************ *)
(*  [Fonc] print_sosa : config -> base -> person -> bool -> unit            *)
(** [Description] : Affiche le picto sosa ainsi que le lien de calcul de
      relation entre la personne et le sosa 1 (si l'option cancel_link
      n'est pas activée).
    [Args] :
      - conf : configuration de la base
      - base : base de donnée
      - p    : la personne que l'on veut afficher
      - link : ce booléen permet d'afficher ou non le lien sur le picto
               sosa. Il n'est pas nécessaire de mettre le lien si on a
               déjà affiché cette personne.
    [Retour] :
      - unit
    [Rem] : Exporté en clair hors de ce module.                             *)
(* ************************************************************************ *)
let print_sosa conf base p link =
  let sosa_num = get_sosa_person p in
  if Sosa.gt sosa_num Sosa.zero then
    match Util.find_sosa_ref conf base with
    | Some r ->
      if link then begin
        let sosa_link =
          let i1 = string_of_iper (get_iper p) in
          let i2 = string_of_iper (get_iper r) in
          let b2 = Sosa.to_string sosa_num in
          "m=RL&i1="
          ^<^ Mutil.encode i1
          ^^^ "&i2="
          ^<^ Mutil.encode i2
          ^^^ "&b1=1&b2="
          ^<^ Mutil.encode b2
        in
        Output.print_sstring conf {|<a href="|} ;
        Output.print_string conf (commd conf) ;
        Output.print_string conf sosa_link ;
        Output.print_sstring conf {|" style="text-decoration:none">|}
      end ;
      let title =
        if is_hide_names conf r && not (authorized_age conf base r)
        then Adef.safe ""
        else
          let direct_ancestor =
            Util.escape_html (p_first_name base r)
            ^^^ " " ^<^ Util.escape_html (p_surname base r)
          in
          ( Printf.sprintf
              (fcapitale (ftransl conf "direct ancestor of %s"))
              (direct_ancestor : Adef.escaped_string :> string)
            |> Adef.safe )
          ^>^
          ( ", Sosa"
            ^ transl conf ":"
            ^ " "
            ^ Sosa.to_string_sep (transl conf "(thousand separator)") sosa_num
          )
      in
      Output.print_sstring conf {|<img src="|} ;
      Output.print_string conf (image_prefix conf) ;
      Output.print_sstring conf {|/sosa.png" alt="sosa" title="|} ;
      Output.print_string conf title ;
      Output.print_sstring conf {|"> |} ;
      if link then Output.print_sstring conf "</a> "
    | None -> ()

(* ************************************************************************ *)
(*  [Fonc] get_death_text : config -> person -> bool -> string      *)
(** [Description] : Retourne une description de la mort de la personne
    [Args] :
    - conf : configuration de la base
    - p    : la personne que l'on veut afficher
    - p_auth : authentifié ou non
      [Retour] :
    - string
      [Rem] : Exporté en clair hors de ce module.                             *)
(* ************************************************************************ *)
let get_death_text conf p p_auth =
  let died =
    if p_auth then
      let is = index_of_sex (get_sex p) in
      match get_death p with
      | Death (dr, _) ->
        begin match dr with
          | Unspecified -> transl_nth conf "died" is |> Adef.safe
          | Murdered -> transl_nth conf "murdered" is |> Adef.safe
          | Killed -> transl_nth conf "killed (in action)" is |> Adef.safe
          | Executed -> transl_nth conf "executed (legally killed)" is |> Adef.safe
          | Disappeared -> transl_nth conf "disappeared" is |> Adef.safe
        end
      | DeadYoung -> transl_nth conf "died young" is |> Adef.safe
      | DeadDontKnowWhen -> transl_nth conf "died" is |> Adef.safe
      | _ -> "" |> Adef.safe
    else "" |> Adef.safe
  in
  let on_death_date =
    match p_auth, get_death p with
    | true, Death (_, d) ->
      let d = Adef.date_of_cdate d in
      begin match List.assoc_opt "long_date" conf.base_env with
        | Some "yes" ->
          DateDisplay.string_of_ondate ~link:false conf d
          ^>^ DateDisplay.get_wday conf d
        | _ -> DateDisplay.string_of_ondate ~link:false conf d
      end
    | _ -> "" |> Adef.safe
  in
  died ^^^ " " ^<^ on_death_date


let get_baptism_text conf p p_auth =
  let baptized =
    if p_auth
    then get_sex p |> index_of_sex |> transl_nth conf "baptized" |> Adef.safe
    else "" |> Adef.safe
  in
  let on_baptism_date =
    match p_auth, Adef.od_of_cdate (get_baptism p) with
    | true, Some d ->
      begin match List.assoc_opt "long_date" conf.base_env with
        | Some "yes" ->
          DateDisplay.string_of_ondate ~link:false conf d
          ^>^ DateDisplay.get_wday conf d
        | _ -> DateDisplay.string_of_ondate ~link:false conf d
      end
    | _ -> "" |> Adef.safe
  in
  baptized ^^^ " " ^<^ on_baptism_date

let get_birth_text conf p p_auth =
  let born =
    if p_auth
    then get_sex p |> index_of_sex |> transl_nth conf "born" |> Adef.safe
    else "" |> Adef.safe
  in
  let on_birth_date =
    match p_auth, Adef.od_of_cdate (get_birth p) with
    | true, Some d ->
      begin match List.assoc_opt "long_date" conf.base_env with
        | Some "yes" ->
          DateDisplay.string_of_ondate ~link:false conf d
          ^>^ DateDisplay.get_wday conf d
        | _ -> DateDisplay.string_of_ondate ~link:false conf d
      end
    | _ -> "" |> Adef.safe
  in
  born ^^^ " " ^<^ on_birth_date

let get_marriage_date_text conf fam p_auth =
  match p_auth, Adef.od_of_cdate (get_marriage fam) with
  | true, Some d ->
    begin match List.assoc_opt "long_date" conf.base_env with
      | Some "yes" ->
        DateDisplay.string_of_ondate ~link:false conf d
        ^>^ DateDisplay.get_wday conf d
      | _ -> DateDisplay.string_of_ondate ~link:false conf d
    end
  | _ -> "" |> Adef.safe

let get_burial_text conf p p_auth =
  let buried =
    if p_auth
    then get_sex p |> index_of_sex |> transl_nth conf "buried" |> Adef.safe
    else "" |> Adef.safe
  in
  let on_burial_date =
    match get_burial p with
    | Buried cod ->
      begin match p_auth, Adef.od_of_cdate cod with
        | true, Some d ->
          begin match List.assoc_opt "long_date" conf.base_env with
            | Some "yes" ->
              DateDisplay.string_of_ondate ~link:false conf d
              ^>^ DateDisplay.get_wday conf d
            | _ -> DateDisplay.string_of_ondate ~link:false conf d
          end
        | _ -> "" |> Adef.safe
      end
    | _ -> "" |> Adef.safe
  in
  buried ^^^ " " ^<^ on_burial_date

let get_cremation_text conf p p_auth =
  let cremated =
    if p_auth
    then get_sex p |> index_of_sex |> transl_nth conf "cremated" |> Adef.safe
    else "" |> Adef.safe
  in
  let on_cremation_date =
    match get_burial p with
    | Cremated cod ->
      begin match p_auth, Adef.od_of_cdate cod with
        | true, Some d ->
          begin match List.assoc_opt "long_date" conf.base_env with
            | Some "yes" ->
              DateDisplay.string_of_ondate ~link:false conf d
              ^>^ DateDisplay.get_wday conf d
            | _ -> DateDisplay.string_of_ondate ~link:false conf d
          end
        | _ -> "" |> Adef.safe
      end
    | _ -> "" |> Adef.safe
  in
  cremated ^^^ " " ^<^ on_cremation_date

let max_ancestor_level conf base ip max_lev =
  let x = ref 0 in
  let mark = Gwdb.iper_marker (Gwdb.ipers base) false in
  (* Loading ITL cache, up to 10 generations. *)
  let () = !GWPARAM_ITL.init_cache conf base ip 10 0 0 in
  let rec loop level ip =
    (* Ne traite pas l'index s'il a déjà été traité. *)
    (* Pose surement probleme pour des implexes. *)
    if not @@ Gwdb.Marker.get mark ip then begin
        (* Met à jour le tableau d'index pour indiquer que l'index est traité. *)
        Gwdb.Marker.set mark ip true ;
        x := max !x level;
        if !x <> max_lev then
          match get_parents (pget conf base ip) with
          | Some ifam ->
              let cpl = foi base ifam in
              loop (succ level) (get_father cpl);
              loop (succ level) (get_mother cpl)
          | _ ->
            x := max !x (!GWPARAM_ITL.max_ancestor_level conf base ip conf.bname max_lev level)
      end
  in
  loop 0 ip; !x

let default_max_cousin_lev = 5

let max_cousin_level conf base p =
  let max_lev =
    try int_of_string (List.assoc "max_cousins_level" conf.base_env) with
      Not_found | Failure _ -> default_max_cousin_lev
  in
  max_ancestor_level conf base (get_iper p) max_lev + 1

let limit_desc conf =
  match Opt.map int_of_string @@ List.assoc_opt "max_desc_level" conf.base_env with
  | Some x -> max 1 x
  | None -> 12

let infinite = 10000

let make_desc_level_table conf base max_level p =
  let line =
    match p_getenv conf.env "t" with
      Some "M" -> Male
    | Some "F" -> Female
    | Some _ | None -> Neuter
  in
  (* the table 'levt' may be not necessary, since I added 'flevt'; kept
     because '%max_desc_level;' is still used... *)
  let levt = Gwdb.iper_marker (Gwdb.ipers base) infinite in
  let flevt = Gwdb.ifam_marker (Gwdb.ifams base) infinite in
  let get = pget conf base in
  let ini_ip = get_iper p in
  let rec fill lev =
    function
      [] -> ()
    | ipl ->
        let new_ipl =
          List.fold_left
            (fun ipl ip ->
               if Gwdb.Marker.get levt ip <= lev then ipl
               else if lev <= max_level then
                 begin
                   Gwdb.Marker.set levt ip lev ;
                   let down =
                     if ip = ini_ip then true
                     else
                       match line with
                       | Male -> get_sex (pget conf base ip) <> Female
                       | Female -> get_sex (pget conf base ip) <> Male
                       | Neuter -> true
                   in
                   if down then
                     Array.fold_left
                       (fun ipl ifam ->
                          if not (Gwdb.Marker.get flevt ifam <= lev)
                          then Gwdb.Marker.set flevt ifam lev ;
                          let ipa = get_children (foi base ifam) in
                          Array.fold_left (fun ipl ip -> ip :: ipl) ipl ipa)
                       ipl (get_family (get ip))
                   else ipl
                 end
               else ipl)
            [] ipl
        in
        fill (succ lev) new_ipl
  in
  fill 0 [ini_ip];
  levt, flevt

let desc_level_max base desc_level_table_l =
  let (levt, _) = Lazy.force desc_level_table_l in
  Gwdb.Collection.fold (fun acc i ->
      let lev = Gwdb.Marker.get levt i in
      if lev != infinite && acc < lev then lev else acc
    ) 0 (Gwdb.ipers base)

let max_descendant_level base desc_level_table_l =
  desc_level_max base desc_level_table_l

(* ancestors by list *)

type generation_person =
    GP_person of Sosa.t * iper * ifam option
  | GP_same of Sosa.t * Sosa.t * iper
  | GP_interv of (Sosa.t * Sosa.t * (Sosa.t * Sosa.t) option) option
  | GP_missing of Sosa.t * iper

let next_generation conf base mark gpl =
  let gpl =
    List.fold_right
      (fun gp gpl ->
         match gp with
           GP_person (n, ip, _) ->
             let n_fath = Sosa.twice n in
             let n_moth = Sosa.inc n_fath 1 in
             let a = pget conf base ip in
             begin match get_parents a with
               Some ifam ->
                 let cpl = foi base ifam in
                 GP_person (n_fath, get_father cpl, Some ifam) ::
                 GP_person (n_moth, get_mother cpl, Some ifam) :: gpl
             | None -> GP_missing (n, ip) :: gpl
             end
         | GP_interv None -> gp :: gpl
         | GP_interv (Some (n1, n2, x)) ->
             let x =
               match x with
                 Some (m1, m2) -> Some (Sosa.twice m1, Sosa.twice m2)
               | None -> None
             in
             let gp = GP_interv (Some (Sosa.twice n1, Sosa.twice n2, x)) in
             gp :: gpl
         | _ -> gpl)
      gpl []
  in
  let gpl =
    List.fold_left
      (fun gpl gp ->
         match gp with
           GP_person (n, ip, _) ->
             let m = Gwdb.Marker.get mark ip in
             if Sosa.eq m Sosa.zero then begin Gwdb.Marker.set mark ip n; gp :: gpl end
             else GP_same (n, m, ip) :: gpl
         | _ -> gp :: gpl)
      [] gpl
  in
  List.rev gpl

let next_generation2 conf base mark gpl =
  let gpl =
    List.map
      (fun gp ->
         match gp with
           GP_same (n, m, _) ->
             GP_interv (Some (n, Sosa.inc n 1, Some (m, Sosa.inc m 1)))
         | _ -> gp)
      gpl
  in
  let gpl = next_generation conf base mark gpl in
  List.fold_right
    (fun gp gpl ->
       match gp, gpl with
         GP_interv (Some (n1, n2, x)), GP_interv (Some (n3, n4, y)) :: gpl1 ->
           if Sosa.eq n2 n3 then
             let z =
               match x, y with
                 Some (m1, m2), Some (m3, m4) ->
                   if Sosa.eq m2 m3 then Some (m1, m4) else None
               | _ -> None
             in
             GP_interv (Some (n1, n4, z)) :: gpl1
           else GP_interv None :: gpl1
       | GP_interv _, GP_interv _ :: gpl -> GP_interv None :: gpl
       | GP_missing (_, _), gpl -> gpl
       | _ -> gp :: gpl)
    gpl []

let sosa_is_present all_gp n1 =
  let rec loop =
    function
      GP_person (n, _, _) :: gpl | GP_same (n, _, _) :: gpl ->
        if Sosa.eq n n1 then true else loop gpl
    | _ :: gpl -> loop gpl
    | [] -> false
  in
  loop all_gp

let get_link all_gp ip =
  let rec loop =
    function
      (GP_person (_, ip0, _) as gp) :: gpl ->
        if ip = ip0 then Some gp else loop gpl
    | _ :: gpl -> loop gpl
    | [] -> None
  in
  loop all_gp

let parent_sosa conf base ip all_gp n parent =
  if sosa_is_present all_gp n then Sosa.to_string n
  else
    match get_parents (pget conf base ip) with
      Some ifam ->
        begin match get_link all_gp (parent (foi base ifam)) with
          Some (GP_person (n, _, _)) -> Sosa.to_string n
        | _ -> ""
        end
    | None -> ""

let will_print =
  function
    GP_person (_, _, _) -> true
  | GP_same (_, _, _) -> true
  | _ -> false

let get_all_generations conf base p =
  let max_level =
    match p_getint conf.env "v" with
      Some v -> v
    | None -> 0
  in
  let mark = Gwdb.iper_marker (Gwdb.ipers base) Sosa.zero in
  let rec get_generations level gpll gpl =
    let gpll = gpl :: gpll in
    if level < max_level then
      let next_gpl = next_generation conf base mark gpl in
      if List.exists will_print next_gpl then
        get_generations (level + 1) gpll next_gpl
      else gpll
    else gpll
  in
  let gpll =
    get_generations 1 [] [GP_person (Sosa.one, get_iper p, None)]
  in
  let gpll = List.rev gpll in List.flatten gpll

(* Ancestors by tree:

  8 ? ? ? ? ? ? ?
   4   5   ?   7
     2       3
         1

1) Build list of levels (t1 = True for parents flag, size 1)
   => [ [8At1 E E] [4Lt1 5Rt1 7At1] [2Lt1 3Rt1] [1Ct1] ]

2) Enrich list of levels (parents flag, sizing)
   => [ [8At1 E E] [4Lt1 5Rf1 7Af1] [2Lt3 3Rt1] [1Ct5] ]

3) Display it
    For each cell:
      Top vertical bar if parents flag (not on top line)
      Person
      Person tree link (vertical bar) ) not on bottom line
      Horizontal line                 )

*)

type pos = Left | Right | Center | Alone
type cell =
    Cell of person * ifam option * pos * bool * int * string
  | Empty

let rec enrich lst1 lst2 =
  match lst1, lst2 with
    _, [] -> []
  | [], lst -> lst
  | Cell (_, _, Right, _, s1, _) :: l1, Cell (p, f, d, u, s2, b) :: l2 ->
      Cell (p, f, d, u, s1 + s2 + 1, b) :: enrich l1 l2
  | Cell (_, _, Left, _, s, _) :: l1, Cell (p, f, d, u, _, b) :: l2 ->
      enrich l1 (Cell (p, f, d, u, s, b) :: l2)
  | Cell (_, _, _, _, s, _) :: l1, Cell (p, f, d, u, _, b) :: l2 ->
      Cell (p, f, d, u, s, b) :: enrich l1 l2
  | Empty :: l1, Cell (p, f, d, _, s, b) :: l2 ->
      Cell (p, f, d, false, s, b) :: enrich l1 l2
  | _ :: l1, Empty :: l2 -> Empty :: enrich l1 l2

let is_empty = List.for_all ((=) Empty)

let rec enrich_tree lst =
  match lst with
    [] -> []
  | head :: tail ->
      if is_empty head then enrich_tree tail
      else
        match tail with
          [] -> [head]
        | thead :: ttail -> head :: enrich_tree (enrich head thead :: ttail)

(* tree_generation_list
    conf: configuration parameters
    base: base name
    gv: number of generations
    p: person *)
let tree_generation_list conf base gv p =
  let next_gen pol =
    List.fold_right begin fun po list ->
      match po with
        Empty -> Empty :: list
      | Cell (p, _, _, _, _, base_prefix) ->
        match get_parents p with
          Some ifam ->
          let cpl = foi base ifam in
          let fath =
            let p = pget conf base (get_father cpl) in
            if not @@ is_empty_name p then Some p else None
          in
          let moth =
            let p = pget conf base (get_mother cpl) in
            if not @@ is_empty_name p then Some p else None
          in
          let fo = Some ifam in
          let base_prefix = conf.bname in
          begin match fath, moth with
              Some f, Some m ->
              Cell (f, fo, Left, true, 1, base_prefix) ::
              Cell (m, fo, Right, true, 1, base_prefix) :: list
            | Some f, None ->
              Cell (f, fo, Alone, true, 1, base_prefix) :: list
            | None, Some m ->
              Cell (m, fo, Alone, true, 1, base_prefix) :: list
            | None, None -> Empty :: list
          end
        | _ ->
          match !GWPARAM_ITL.tree_generation_list conf base base_prefix p with
          | Some (fath, if1, base_prefix1), Some (moth, if2, base_prefix2) ->
            Cell (fath, Some if1, Left, true, 1, base_prefix1)
            :: Cell (moth, Some if2, Right, true, 1, base_prefix2)
            :: list
          | Some (fath, ifam, base_prefix), None ->
            Cell (fath, Some ifam, Alone, true, 1, base_prefix) :: list
          | None, Some (moth, ifam, base_prefix) ->
            Cell (moth, Some ifam, Alone, true, 1, base_prefix) :: list
          | None, None -> Empty :: list
    end pol []
  in
  let gen =
    let rec loop i gen list =
      if i = 0 then gen :: list else loop (i - 1) (next_gen gen) (gen :: list)
    in
    loop (gv - 1) [Cell (p, None, Center, true, 1, conf.bname)] []
  in
  enrich_tree gen

(* Ancestors surnames list *)

let get_date_place conf base auth_for_all_anc p =
  if auth_for_all_anc || authorized_age conf base p then
    let d1 =
      match Adef.od_of_cdate (get_birth p) with
        None -> Adef.od_of_cdate (get_baptism p)
      | x -> x
    in
    let d1 =
      if d1 <> None then d1
      else
        Array.fold_left
          (fun d ifam ->
             if d <> None then d
             else Adef.od_of_cdate (get_marriage (foi base ifam)))
          d1 (get_family p)
    in
    let d2 =
      match get_death p with
        Death (_, cd) -> Some (Adef.date_of_cdate cd)
      | _ ->
          match get_burial p with
            Buried cod -> Adef.od_of_cdate cod
          | Cremated cod -> Adef.od_of_cdate cod
          | _ -> None
    in
    let auth_for_all_anc =
      if auth_for_all_anc then true
      else
        match d2 with
          Some (Dgreg (d, _)) ->
            let a = Date.time_elapsed d conf.today in
            Util.strictly_after_private_years conf a
        | _ -> false
    in
    let pl =
      let pl = "" in
      let pl = if pl <> "" then pl else sou base (get_birth_place p) in
      let pl = if pl <> "" then pl else sou base (get_baptism_place p) in
      let pl = if pl <> "" then pl else sou base (get_death_place p) in
      let pl = if pl <> "" then pl else sou base (get_burial_place p) in
      if pl <> "" then pl
      else
        Array.fold_left
          (fun pl ifam ->
             if pl <> "" then pl
             else sou base (get_marriage_place (foi base ifam)))
          pl (get_family p)
    in
    (d1, d2, pl), auth_for_all_anc
  else (None, None, ""), false

(* duplications proposed for merging *)

type dup =
    DupFam of ifam * ifam
  | DupInd of iper * iper
  | NoDup
type excl_dup = (iper * iper) list * (ifam * ifam) list

let gen_excluded_possible_duplications conf s i_of_string =
  match p_getenv conf.env s with
    Some s ->
      let rec loop ipl i =
        if i >= String.length s then ipl
        else
          let j =
            try String.index_from s i ',' with Not_found -> String.length s
          in
          if j = String.length s then ipl
          else
            let k =
              try String.index_from s (j + 1) ',' with
                Not_found -> String.length s
            in
            let s1 = String.sub s i (j - i) in
            let s2 = String.sub s (j + 1) (k - j - 1) in
            let ipl =
              try (i_of_string s1, i_of_string s2) :: ipl
              with _ -> ipl
            in
            loop ipl (k + 1)
      in
      loop [] 0
  | None -> []

let excluded_possible_duplications conf =
  gen_excluded_possible_duplications conf "iexcl" iper_of_string,
  gen_excluded_possible_duplications conf "fexcl" ifam_of_string

let first_possible_duplication_children iexcl len child eq =
  let rec loop i =
    if i = len then NoDup
    else begin
      let c1 = child i in
      let rec loop' j =
        if j = len then loop (i + 1)
        else begin
          let c2 = child j in
          let ic1 = get_iper c1 in
          let ic2 = get_iper c2 in
          if List.mem (ic1, ic2) iexcl then loop' (j + 1)
          else if eq (get_first_name c1) (get_first_name c2)
          then DupInd (ic1, ic2)
          else loop' (j + 1)
        end
      in loop' (i + 1)
    end
  in loop 0

let first_possible_duplication base ip (iexcl, fexcl) =
  let str =
    let cache = ref [] in
    fun i ->
      match List.assoc_opt i !cache with
      | Some s -> s
      | None ->
        let s = Name.lower @@ sou base i in
        cache := (i, s) :: !cache ;
        s
  in
  let eq i1 i2 = str i1 = str i2 in
  let p = poi base ip in
  match get_family p with
  | [| |] -> NoDup
  | [| ifam |] ->
    let children = get_children @@ foi base ifam in
    let len = Array.length children in
    if len < 2 then NoDup
    else begin
      let child i = poi base @@ Array.unsafe_get children i in
      first_possible_duplication_children iexcl len child eq
    end
  | ifams ->
    let len = Array.length ifams in
    let fams = Array.make len None in
    let spouses = Array.make len None in
    let fam i =
      match Array.unsafe_get fams i with
      | Some f -> f
      | None ->
        let f = foi base @@ Array.unsafe_get ifams i in
        Array.unsafe_set fams i (Some f) ;
        f
    in
    let spouse i =
      match Array.unsafe_get spouses i with
      | Some sp -> sp
      | None ->
        let sp = poi base @@ Gutil.spouse ip @@ fam i in
        Array.unsafe_set spouses i (Some sp) ;
        sp
    in
    let dup =
      let rec loop i =
        if i = len then NoDup
        else
          let sp1 = spouse i in
          let rec loop' j =
            if j = len then loop (i + 1)
            else
              let sp2 = spouse j in
              if get_iper sp1 = get_iper sp2
              then
                let ifam1 = Array.unsafe_get ifams i in
                let ifam2 = Array.unsafe_get ifams j in
                if not (List.mem (ifam2, ifam2) fexcl)
                then DupFam (ifam1, ifam2)
                else loop' (j + 1)
              else
                let isp1 = get_iper sp1 in
                let isp2 = get_iper sp2 in
                if List.mem (isp1, isp2) iexcl then loop' (j + 1)
                else if eq (get_first_name sp1) (get_first_name sp2)
                     && eq (get_surname sp1) (get_surname sp2)
                then DupInd (isp1, isp2)
                else loop' (j + 1)
          in loop' (i + 1)
      in loop 0
    in
    if dup <> NoDup then dup
    else begin
      let ichildren =
        Array.fold_left Array.append [||] @@ Array.init len (fun i -> get_children @@ fam i)
      in
      let len = Array.length ichildren in
      let children = Array.make len None in
      let child i =
        match Array.unsafe_get children i with
        | Some c -> c
        | None ->
          let c = poi base @@ Array.unsafe_get ichildren i in
          Array.unsafe_set children i (Some c) ;
          c
      in
      first_possible_duplication_children iexcl len child eq
    end

let has_possible_duplications conf base p =
  let ip = get_iper p in
  let excl = excluded_possible_duplications conf in
  first_possible_duplication base ip excl <> NoDup

let merge_date_place conf base surn ((d1, d2, pl), auth) p =
  let ((pd1, pd2, ppl), auth) = get_date_place conf base auth p in
  let nd1 =
    if pd1 <> None then pd1
    else if eq_istr (get_surname p) surn then if pd2 <> None then pd2 else d1
    else None
  in
  let nd2 =
    if eq_istr (get_surname p) surn then
      if d2 <> None then d2
      else if d1 <> None then d1
      else if pd1 <> None then pd2
      else pd1
    else if pd2 <> None then pd2
    else if pd1 <> None then pd1
    else d1
  in
  let pl =
    if ppl <> "" then ppl else if eq_istr (get_surname p) surn then pl else ""
  in
  (nd1, nd2, pl), auth

let build_surnames_list conf base v p =
  let ht = Hashtbl.create 701 in
  let mark =
    let n =
      try int_of_string (List.assoc "max_ancestor_implex" conf.base_env)
      with _ -> 5
    in
    Gwdb.iper_marker (Gwdb.ipers base) n
  in
  let auth = conf.wizard || conf.friend in
  let add_surname sosa p surn dp =
    let r =
      try Hashtbl.find ht surn with
        Not_found -> let r = ref ((fst dp, p), []) in Hashtbl.add ht surn r; r
    in
    r := fst !r, sosa :: snd !r
  in
  let rec loop lev sosa p surn dp =
    if Gwdb.Marker.get mark (get_iper p) = 0 then ()
    else if lev = v then
      if is_hide_names conf p && not (authorized_age conf base p) then ()
      else add_surname sosa p surn dp
    else
      begin
        Gwdb.Marker.set mark
          (get_iper p) (Gwdb.Marker.get mark (get_iper p) - 1) ;
        match get_parents p with
          Some ifam ->
            let cpl = foi base ifam in
            let fath = pget conf base (get_father cpl) in
            let moth = pget conf base (get_mother cpl) in
            if not (eq_istr surn (get_surname fath)) &&
               not (eq_istr surn (get_surname moth))
            then
              add_surname sosa p surn dp;
            let sosa = Sosa.twice sosa in
            if not (is_hidden fath) then
              begin let dp1 = merge_date_place conf base surn dp fath in
                loop (lev + 1) sosa fath (get_surname fath) dp1
              end;
            let sosa = Sosa.inc sosa 1 in
            if not (is_hidden moth) then
              let dp2 = merge_date_place conf base surn dp moth in
              loop (lev + 1) sosa moth (get_surname moth) dp2
        | None -> add_surname sosa p surn dp
      end
  in
  loop 1 Sosa.one p (get_surname p) (get_date_place conf base auth p);
  let list = ref [] in
  Hashtbl.iter
    (fun i dp ->
       let surn = sou base i in
       if surn <> "?" then list := (surn, !dp) :: !list)
    ht;
  List.sort
    (fun (s1, _) (s2, _) ->
       match
         Gutil.alphabetic_order (surname_without_particle base s1) (surname_without_particle base s2)
       with
         0 ->
           Gutil.alphabetic_order (surname_particle base s1)
             (surname_particle base s2)
       | x -> x)
    !list


(* ************************************************************************* *)
(*  [Fonc] build_list_eclair :
      config -> base -> int -> person ->
        list
          (string * string * option date * option date * person * list iper) *)
(** [Description] : Construit la liste éclair des ascendants de p jusqu'à la
                    génération v.
    [Args] :
      - conf : configuration de la base
      - base : base de donnée
      - v    : le nombre de génération
      - p    : person
    [Retour] : (surname * place * date begin * date end * person * list iper)
    [Rem] : Exporté en clair hors de ce module.                              *)
(* ************************************************************************* *)
let build_list_eclair conf base v p =
  let ht = Hashtbl.create 701 in
  let mark = Gwdb.iper_marker (Gwdb.ipers base) false in
  (* Fonction d'ajout dans la Hashtbl. A la clé (surname, place) on associe *)
  (* la personne (pour l'interprétation dans le template), la possible date *)
  (* de début, la possible date de fin, la liste des personnes/évènements.  *)
  (* Astuce: le nombre d'élément de la liste correspond au nombre             *)
  (* d'évènements et le nombre d'iper unique correspond au nombre d'individu. *)
  let add_surname p surn pl d =
    if not (is_empty_string pl) then
      let pl = Util.string_of_place conf (sou base pl) in
      let r =
        try Hashtbl.find ht (surn, pl) with
          Not_found ->
            let r = ref (p, None, None, []) in Hashtbl.add ht (surn, pl) r; r
      in
      (* Met la jour le binding : dates et liste des iper. *)
      r :=
        (fun p (pp, db, de, l) ->
           let db =
             match db with
               Some dd ->
                 begin match d with
                   Some d -> if Date.compare_date d dd < 0 then Some d else db
                 | None -> db
                 end
             | None -> d
           in
           let de =
             match de with
               Some dd ->
                 begin match d with
                   Some d -> if Date.compare_date d dd > 0 then Some d else de
                 | None -> de
                 end
             | None -> d
           in
           pp, db, de, get_iper p :: l)
          p !r
  in
  (* Fonction d'ajout de tous les évènements d'une personne (birth, bapt...). *)
  let add_person p surn =
    if Gwdb.Marker.get mark (get_iper p) then ()
    else
      begin
        Gwdb.Marker.set mark (get_iper p) true;
        add_surname p surn (get_birth_place p)
          (Adef.od_of_cdate (get_birth p));
        add_surname p surn (get_baptism_place p)
          (Adef.od_of_cdate (get_baptism p));
        let death =
          match get_death p with
            Death (_, cd) -> Some (Adef.date_of_cdate cd)
          | _ -> None
        in
        add_surname p surn (get_death_place p) death;
        let burial =
          match get_burial p with
            Buried cod | Cremated cod -> Adef.od_of_cdate cod
          | _ -> None
        in
        add_surname p surn (get_burial_place p) burial;
        Array.iter
          (fun ifam ->
             let fam = foi base ifam in
             add_surname p surn (get_marriage_place fam)
               (Adef.od_of_cdate (get_marriage fam)))
          (get_family p)
      end
  in
  (* Parcours les ascendants de p et les ajoute dans la Hashtbl. *)
  let rec loop lev p surn =
    if lev = v then
      if is_hide_names conf p && not (authorized_age conf base p) then ()
      else add_person p surn
    else
      begin
        add_person p surn;
        match get_parents p with
          Some ifam ->
            let cpl = foi base ifam in
            let fath = pget conf base (get_father cpl) in
            let moth = pget conf base (get_mother cpl) in
            if not (is_hidden fath) then
              loop (lev + 1) fath (get_surname fath);
            if not (is_hidden moth) then
              loop (lev + 1) moth (get_surname moth)
        | None -> ()
      end
  in
  (* Construction de la Hashtbl. *)
  loop 1 p (get_surname p);
  (* On parcours la Hashtbl, et on élimine les noms vide (=?) *)
  let list = ref [] in
  Hashtbl.iter
    (fun (istr, place) ht_val ->
       let surn = sou base istr in
       if surn <> "?" then
         let (p, db, de, pl) = (fun x -> x) !ht_val in
         list := (surn, place, db, de, p, pl) :: !list)
    ht;
  (* On trie la liste par nom, puis lieu. *)
  List.sort begin fun (s1, pl1, _, _, _, _) (s2, pl2, _, _, _, _) ->
    match
      Gutil.alphabetic_order (surname_without_particle base s1) (surname_without_particle base s2)
    with
    | 0 ->
      begin
        match
          Gutil.alphabetic_order (surname_particle base s1) (surname_particle base s2)
        with
        | 0 -> Gutil.alphabetic_order (pl1 : Adef.escaped_string :> string) (pl2 : Adef.escaped_string :> string)
        | x -> x
      end
    | x -> x
  end !list

let linked_page_text conf base p s key (str : Adef.safe_string) (pg, (_, il)) : Adef.safe_string =
  match pg with
  | Def.NLDB.PgMisc pg ->
    let list = List.map snd (List.filter (fun (k, _) -> k = key) il) in
    List.fold_right begin fun text (str : Adef.safe_string) ->
      try
        let (nenv, _) = Notes.read_notes base pg in
        let v =
          let v = List.assoc s nenv in
          if v = "" then raise Not_found
          else Util.nth_field v (Util.index_of_sex (get_sex p))
        in
        match text.Def.NLDB.lnTxt with
        | Some "" -> str
        | _ ->
          let str1 =
            let v =
              let text = text.Def.NLDB.lnTxt in
              match text with
                Some text ->
                let rec loop i len =
                  if i = String.length text then Buff.get len
                  else if text.[i] = '*' then
                    loop (i + 1) (Buff.mstore len v)
                  else loop (i + 1) (Buff.store len text.[i])
                in
                loop 0 0
              | None -> v
            in
            let (a, b, c) =
              try
                let i = String.index v '{' in
                let j = String.index v '}' in
                let a = String.sub v 0 i in
                let b = String.sub v (i + 1) (j - i - 1) in
                let c = String.sub v (j + 1) (String.length v - j - 1) in
                a |> Util.safe_html, b |> Util.safe_html, c |> Util.safe_html
              with Not_found -> Adef.safe "", Util.safe_html v, Adef.safe ""
            in
            (a : Adef.safe_string)
            ^^^ {|<a href="|}
            ^<^ ( (commd conf)
                  ^^^ {|m=NOTES&f=|}
                  ^<^ (Mutil.encode pg :> Adef.escaped_string)
                  ^>^ {|#p_|} ^ (string_of_int text.Def.NLDB.lnPos)
                  : Adef.escaped_string :> Adef.safe_string)
            ^^^ {|">|}
            ^<^ b
            ^^^ {|</a>|}
            ^<^ c
          in
          if (str :> string) = "" then str1 else str ^^^ ", " ^<^ str1
      with Not_found -> str
    end list str
  | _ -> str

let links_to_ind conf base db key =
  let list =
    List.fold_left
      (fun pgl (pg, (_, il)) ->
         let record_it =
           match pg with
             Def.NLDB.PgInd ip ->
               authorized_age conf base (pget conf base ip)
           | Def.NLDB.PgFam ifam ->
               authorized_age conf base (pget conf base (get_father @@ foi base ifam))
           | Def.NLDB.PgNotes | Def.NLDB.PgMisc _ |
             Def.NLDB.PgWizard _ ->
               true
         in
         if record_it then
           List.fold_left
             (fun pgl (k, _) -> if k = key then pg :: pgl else pgl) pgl il
         else pgl)
      [] db
  in
  List.sort_uniq compare list

(* Interpretation of template file *)

let rec compare_ls sl1 sl2 =
  match sl1, sl2 with
    s1 :: sl1, s2 :: sl2 ->
      (* Je ne sais pas s'il y a des effets de bords, mais on  *)
      (* essaie de convertir s1 s2 en int pour éviter que "10" *)
      (* soit plus petit que "2". J'espère qu'on ne casse pas  *)
      (* les performances à cause du try..with.                *)
      let c =
        try Stdlib.compare (int_of_string s1) (int_of_string s2) with
          Failure _ -> Gutil.alphabetic_order s1 s2
      in
      if c = 0 then compare_ls sl1 sl2 else c
  | _ :: _, [] -> 1
  | [], _ :: _ -> -1
  | [], [] -> 0

module SortedList =
  Set.Make (struct type t = string list let compare = compare_ls end)

(*
   Type pour représenté soit :
     - la liste des branches patronymique
       (surname * date begin * date end * place * person * list sosa * loc)
     - la liste éclair
       (surname * place * date begin * date end * person * list iper * loc)
*)
type ancestor_surname_info =
  | Branch of
      (string * date option * date option * string * person * Sosa.t list * loc)
  | Eclair of
      (string * Adef.safe_string * date option * date option * person * iper list * loc)

type 'a env =
    Vallgp of generation_person list
  | Vanc of generation_person
  | Vanc_surn of ancestor_surname_info
  | Vcell of cell
  | Vcelll of cell list
  | Vcnt of int ref
  | Vdesclevtab of ((iper, int) Marker.t * (ifam, int) Marker.t) lazy_t
  | Vdmark of (iper, bool) Marker.t ref
  | Vslist of SortedList.t ref
  | Vslistlm of string list list
  | Vind of person
  | Vfam of ifam * family * (iper * iper * iper) * bool
  | Vrel of relation * person option
  | Vbool of bool
  | Vint of int
  | Vgpl of generation_person list
  | Vnldb of (Gwdb.iper, Gwdb.ifam) Def.NLDB.t
  | Vstring of string
  | Vsosa_ref of person option
  | Vsosa of (iper * (Sosa.t * person) option) list ref
  | Vt_sosa of sosa_t option
  | Vtitle of person * title_item
  | Vevent of person * event_item
  | Vlazyp of string option ref
  | Vlazy of 'a env Lazy.t
  | Vother of 'a
  | Vnone
and title_item =
  int * istr gen_title_name * istr * istr list *
    (date option * date option) list
and event_item =
  event_name * cdate * istr * istr * istr * (iper * witness_kind) array *
    iper option
and event_name =
    Pevent of istr gen_pers_event_name
  | Fevent of istr gen_fam_event_name

let get_env v env =
  try
    match List.assoc v env with
      Vlazy l -> Lazy.force l
    | x -> x
  with Not_found -> Vnone
let get_vother =
  function
    Vother x -> Some x
  | _ -> None
let set_vother x = Vother x

let extract_var sini s =
  let len = String.length sini in
  if String.length s > len && String.sub s 0 (String.length sini) = sini then
    String.sub s len (String.length s - len)
  else ""

let template_file = ref "perso.txt"

let warning_use_has_parents_before_parent (fname, bp, ep) var r =
  Printf.sprintf
    "%s %d-%d: since v5.00, must test \"has_parents\" before using \"%s\"\n"
    fname bp ep var
  |> !GWPARAM.syslog `LOG_WARNING ;
  r

let bool_val x = VVbool x
let str_val x = VVstring x
let null_val = VVstring ""
let safe_val (x : [< `encoded | `escaped | `safe] Adef.astring) =
  VVstring ((x :> Adef.safe_string) :> string)

let gen_string_of_img_sz max_wid max_hei conf base (p, p_auth) =
  if p_auth then
    let v = image_and_size conf base p (limited_image_size max_wid max_hei) in
    match v with
      Some (_, _, Some (width, height)) ->
        Format.sprintf " width=\"%d\" height=\"%d\"" width height
    | Some (_, _, None) -> Format.sprintf " height=\"%d\"" max_hei
    | None -> ""
  else ""
let string_of_image_size = gen_string_of_img_sz max_im_wid max_im_wid
let string_of_image_medium_size = gen_string_of_img_sz 160 120
let string_of_image_small_size = gen_string_of_img_sz 100 75

let get_sosa conf base env r p =
  try List.assoc (get_iper p) !r with
    Not_found ->
      let s =
        match get_env "sosa_ref" env with
          Vsosa_ref v ->
            begin match get_env "t_sosa" env with
              | Vt_sosa (Some t_sosa) -> find_sosa conf base p v t_sosa
              | _ -> None
            end
        | _ -> None
      in
      r := (get_iper p, s) :: !r; s

(* ************************************************************************** *)
(*  [Fonc] get_linked_page : config -> base -> person -> string -> string     *)
(** [Description] : Permet de récupérer un lien de la chronique familiale.
    [Args] :
      - conf : configuration
      - base : base de donnée
      - p    : person
      - s    : nom du lien (eg. "HEAD", "OCCU", "BIBLIO", "BNOTE", "DEATH")
    [Retour] : string : "<a href="xxx">description du lien</a>"
    [Rem] : Exporté en clair hors de ce module.                               *)
(* ************************************************************************** *)
let get_linked_page conf base p s =
  let db = Gwdb.read_nldb base in
  let db = Notes.merge_possible_aliases conf db in
  let key =
    let fn = Name.lower (sou base (get_first_name p)) in
    let sn = Name.lower (sou base (get_surname p)) in fn, sn, get_occ p
  in
  List.fold_left (linked_page_text conf base p s key) (Adef.safe "") db

let events_list conf base p =
  let pevents =
    if authorized_age conf base p then
      List.fold_right
        (fun evt events ->
           let name = Pevent evt.epers_name in
           let date = evt.epers_date in
           let place = evt.epers_place in
           let note = evt.epers_note in
           let src = evt.epers_src in
           let wl = evt.epers_witnesses in
           let x = name, date, place, note, src, wl, None in x :: events)
        (get_pevents p) []
    else []
  in
  let get_name = function
    | (Pevent n, _, _, _, _, _, _) -> CheckItem.Psort n
    | (Fevent n, _, _, _, _, _, _) -> CheckItem.Fsort n
  in
  let get_date (_, date, _, _, _, _, _) = date in
  let fevents =
    (* On conserve l'ordre des familles. *)
    Array.fold_right
      (fun ifam fevents ->
         let fam = foi base ifam in
         let ifath = get_father fam in
         let imoth = get_mother fam in
         let isp = Gutil.spouse (get_iper p) fam in
         let m_auth =
           authorized_age conf base (pget conf base ifath) &&
           authorized_age conf base (pget conf base imoth)
         in
         let fam_fevents =
           if m_auth then
             List.fold_right
               (fun evt fam_fevents ->
                  let name = Fevent evt.efam_name in
                  let date = evt.efam_date in
                  let place = evt.efam_place in
                  let note = evt.efam_note in
                  let src = evt.efam_src in
                  let wl = evt.efam_witnesses in
                  let x = name, date, place, note, src, wl, Some isp in
                  x :: fam_fevents)
               (get_fevents fam) []
           else []
         in
         CheckItem.merge_events get_name get_date fam_fevents fevents)
      (get_family p) []
  in
  CheckItem.merge_events get_name get_date pevents fevents

let make_ep conf base ip =
  let p = pget conf base ip in
  let p_auth = authorized_age conf base p in p, p_auth

let make_efam conf base ip ifam =
  let fam = foi base ifam in
  let ifath = get_father fam in
  let imoth = get_mother fam in
  let ispouse = if ip = ifath then imoth else ifath in
  let cpl = ifath, imoth, ispouse in
  let m_auth =
    authorized_age conf base (pget conf base ifath) &&
    authorized_age conf base (pget conf base imoth)
  in
  fam, cpl, m_auth

let mode_local env =
  match get_env "fam_link" env with
  | Vfam _ -> false
  | _ -> true

let get_note_source conf base env auth no_note note_source =
  if auth && not no_note
  then Notes.source_note_with_env conf base env note_source
  else Adef.safe ""

let date_aux conf p_auth date =
  match p_auth, Adef.od_of_cdate date with
  | true, Some d ->
    if List.assoc_opt "long_date" conf.base_env = Some "yes"
    then DateDisplay.string_of_ondate conf d ^>^ DateDisplay.get_wday conf d
         |> safe_val
    else DateDisplay.string_of_ondate conf d |> safe_val
  | _ -> null_val

let rec eval_var conf base env ep loc sl =
  try eval_simple_var conf base env ep sl with
    Not_found -> eval_compound_var conf base env ep loc sl
and eval_simple_var conf base env ep = function
  | [s] ->
    begin
      try bool_val (eval_simple_bool_var conf base env s)
      with Not_found -> eval_simple_str_var conf base env ep s
    end
  | _ -> raise Not_found
and eval_simple_bool_var conf base env =
  let fam_check_aux fn =
    match get_env "fam" env with
    | Vfam (_, fam, _, _) when mode_local env -> fn fam
    | _ ->
      match get_env "fam_link" env with
      | Vfam (_, fam, _, _) -> fn fam
      | _ -> raise Not_found
  in
  let check_relation test =
    fam_check_aux (fun fam -> test @@ get_relation fam)
  in
  function
  | "are_divorced" ->
    fam_check_aux (fun fam -> match get_divorce fam with Divorced _ -> true | _ -> false)
  | "are_engaged" ->
    check_relation ((=) Engaged)
  | "are_married" ->
    check_relation (function Married | NoSexesCheckMarried -> true | _ -> false)
  | "are_not_married" ->
    check_relation (function NotMarried | NoSexesCheckNotMarried -> true | _ -> false)
  | "are_pacs" ->
    check_relation ((=) Pacs)
  | "are_marriage_banns" ->
    check_relation ((=) MarriageBann)
  | "are_marriage_contract" ->
    check_relation ((=) MarriageContract)
  | "are_marriage_license" ->
    check_relation ((=) MarriageLicense)
  | "are_residence" ->
    check_relation ((=) Residence)
  | "are_separated" ->
    fam_check_aux (fun fam -> get_divorce fam = Separated)
  | "browsing_with_sosa_ref" ->
    begin match get_env "sosa_ref" env with
      | Vsosa_ref v -> v <> None
      | _ -> raise Not_found
    end
  | "has_comment" | "has_fnotes" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) when mode_local env ->
        m_auth && not conf.no_note && sou base (get_comment fam) <> ""
      | _ ->
        match get_env "fam_link" env with
          Vfam (_, _, _, _) -> false
        | _ -> raise Not_found
    end
  | "has_fsources" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        m_auth && sou base (get_fsources fam) <> ""
      | _ -> false
    end
  | "has_marriage_note" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        m_auth && not conf.no_note && sou base (get_marriage_note fam) <> ""
      | _ -> raise Not_found
    end
  | "has_marriage_source" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        m_auth && sou base (get_marriage_src fam) <> ""
      | _ -> raise Not_found
    end
  | "has_relation_her" ->
    begin match get_env "rel" env with
        Vrel ({r_moth = Some _}, None) -> true
      | _ -> false
    end
  | "has_relation_him" ->
    begin match get_env "rel" env with
        Vrel ({r_fath = Some _}, None) -> true
      | _ -> false
    end
  | "has_witnesses" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) when mode_local env ->
        m_auth && Array.length (get_witnesses fam) > 0
      | _ ->
        match get_env "fam_link" env with
          Vfam (_, _, _, _) -> false
        | _ -> raise Not_found
    end
  | "is_first" ->
    begin match get_env "first" env with
        Vbool x -> x
      | _ -> raise Not_found
    end
  | "is_last" ->
    begin match get_env "last" env with
        Vbool x -> x
      | _ -> raise Not_found
    end
  | "is_no_mention" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, _) when mode_local env -> get_relation fam = NoMention
      | _ ->
        match get_env "fam_link" env with
          Vfam (_, fam, _, _) -> get_relation fam = NoMention
        | _ -> raise Not_found
    end
  | "is_no_sexes_check" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, _) when mode_local env ->
        get_relation fam = NoSexesCheckNotMarried ||
        get_relation fam = NoSexesCheckMarried
      | _ ->
        match get_env "fam_link" env with
          Vfam (_, fam, _, _) ->
          get_relation fam = NoSexesCheckNotMarried ||
          get_relation fam = NoSexesCheckMarried
        | _ -> raise Not_found
    end
  | "is_self" -> get_env "pos" env = Vstring "self"
  | "is_sibling_after" -> get_env "pos" env = Vstring "next"
  | "is_sibling_before" -> get_env "pos" env = Vstring "prev"
  | "lazy_printed" ->
    begin match get_env "lazy_print" env with
        Vlazyp r -> !r = None
      | _ -> raise Not_found
    end
  | s ->
    let v = extract_var "file_exists_" s in
    if v <> "" then
      SrcfileDisplay.source_file_name conf v
      |> Sys.file_exists
    else raise Not_found
and eval_simple_str_var conf base env (_, p_auth) =
  function
  | "alias" ->
    begin match get_env "alias" env with
        Vstring s -> s |> Util.escape_html |> safe_val
      | _ -> raise Not_found
    end
  | "child_cnt" -> string_of_int_env "child_cnt" env
  | "comment" | "fnotes" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        get_comment fam
        |> sou base
        |> get_note_source conf base [] m_auth conf.no_note
        |> safe_val
      | _ -> raise Not_found
    end
  | "count" ->
    begin match get_env "count" env with
        Vcnt c -> str_val (string_of_int !c)
      | _ -> null_val
    end
  | "count1" ->
    begin match get_env "count1" env with
        Vcnt c -> str_val (string_of_int !c)
      | _ -> null_val
    end
  | "count2" ->
    begin match get_env "count2" env with
        Vcnt c -> str_val (string_of_int !c)
      | _ -> null_val
    end
  | "divorce_date" ->
    begin match get_env "fam" env with
      | Vfam (_, fam, _, m_auth) when mode_local env ->
        begin match get_divorce fam with
          | Divorced d ->
            begin match date_aux conf m_auth d with
              | VVstring s when s <> "" -> VVstring ("<em>" ^ s ^ "</em>")
              | x -> x
            end
          | _ -> raise Not_found
        end
      | _ ->
        match get_env "fam_link" env with
        | Vfam (_, fam, _, m_auth) ->
          begin match get_divorce fam with
            | Divorced d ->
              begin match date_aux conf m_auth d with
                | VVstring s when s <> "" -> VVstring ("<em>" ^ s ^ "</em>")
                | x -> x
              end
            | _ -> raise Not_found
          end
        | _ -> raise Not_found
    end
  | "slash_divorce_date" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        begin match get_divorce fam with
            Divorced d ->
            let d = Adef.od_of_cdate d in
            begin match d with
                Some d when m_auth ->
                DateDisplay.string_slash_of_date conf d |> safe_val
              | _ -> null_val
            end
          | _ -> raise Not_found
        end
      | _ -> raise Not_found
    end
  | "empty_sorted_list" ->
    begin match get_env "list" env with
      | Vslist l -> l := SortedList.empty ; null_val
      | _ -> raise Not_found
    end
  | "empty_sorted_listb" ->
    begin match get_env "listb" env with
      | Vslist l -> l := SortedList.empty ; null_val
      | _ -> raise Not_found
    end
  | "empty_sorted_listc" ->
    begin match get_env "listc" env with
      | Vslist l -> l := SortedList.empty ; null_val
      | _ -> raise Not_found
    end
  | "family_cnt" -> string_of_int_env "family_cnt" env
  | "first_name_alias" ->
    begin match get_env "first_name_alias" env with
        Vstring s -> s |> Util.escape_html |> safe_val
      | _ -> null_val
    end
  | "fsources" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, _) ->
        get_fsources fam
        |> sou base
        |> Util.safe_html
        |> safe_val
      | _ -> null_val
    end
  | "incr_count" ->
    begin match get_env "count" env with
        Vcnt c -> incr c; null_val
      | _ -> null_val
    end
  | "incr_count1" ->
    begin match get_env "count1" env with
        Vcnt c -> incr c; null_val
      | _ -> null_val
    end
  | "incr_count2" ->
    begin match get_env "count2" env with
        Vcnt c -> incr c; null_val
      | _ -> null_val
    end
  | "lazy_force" ->
    begin match get_env "lazy_print" env with
        Vlazyp r ->
        begin match !r with
            Some s -> r := None; safe_val (Adef.safe s)
          | None -> null_val
        end
      | _ -> raise Not_found
    end
  | "level" ->
    begin match get_env "level" env with
        Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "marriage_place" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) when mode_local env ->
        if m_auth
        then
          get_marriage_place fam
          |> sou base
          |> Util.string_of_place conf
          |> safe_val
        else null_val
      | _ ->
        match get_env "fam_link" env with
          Vfam (_, fam, _, m_auth) ->
          if m_auth then
            get_marriage_place fam
            |> sou base
            |> Util.string_of_place conf
            |> safe_val
          else null_val
        | _ -> raise Not_found
    end
  | "marriage_note" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        get_marriage_note fam
        |> sou base
        |> get_note_source conf base [] m_auth conf.no_note
        |> safe_val
      | _ -> raise Not_found
    end
  | "marriage_source" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        get_marriage_src fam
        |> sou base
        |> get_note_source conf base [] m_auth false
        |> safe_val
      | _ -> raise Not_found
    end
  | "max_anc_level" ->
    begin match get_env "max_anc_level" env with
        Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "static_max_anc_level" ->
    begin match get_env "static_max_anc_level" env with
        Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "sosa_ref_max_anc_level" ->
    begin match get_env "sosa_ref_max_anc_level" env with
      | Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "max_cous_level" ->
    begin match get_env "max_cous_level" env with
        Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "max_desc_level" ->
    begin match get_env "max_desc_level" env with
        Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "static_max_desc_level" ->
    begin match get_env "static_max_desc_level" env with
      | Vint i -> str_val (string_of_int i)
      | _ -> null_val
    end
  | "nobility_title" ->
    begin match get_env "nobility_title" env with
        Vtitle (p, t) ->
        if p_auth then
          string_of_title conf base (transl_nth conf "and" 0 |> Adef.safe) p t
          |> safe_val
        else null_val
      | _ -> raise Not_found
    end
  | "number_of_subitems" ->
    begin match get_env "item" env with
        Vslistlm ((s :: _) :: sll) ->
        let n =
          let rec loop n =
            function
              (s1 :: _) :: sll -> if s = s1 then loop (n + 1) sll else n
            | _ -> n
          in
          loop 1 sll
        in
        str_val (string_of_int n)
      | _ -> raise Not_found
    end
  | "on_marriage_date" ->
    begin match get_env "fam" env with
      | Vfam (_, fam, _, m_auth) when mode_local env ->
        date_aux conf m_auth (get_marriage fam)
      | _ ->
        match get_env "fam_link" env with
        | Vfam (_, fam, _, m_auth) ->
          date_aux conf m_auth (get_marriage fam)
        | _ -> raise Not_found
    end
  | "slash_marriage_date" ->
    begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
        begin match m_auth, Adef.od_of_cdate (get_marriage fam) with
            true, Some s -> DateDisplay.string_slash_of_date conf s |> safe_val
          | _ -> null_val
        end
      | _ -> raise Not_found
    end
  | "origin_file" ->
    if conf.wizard then
      match get_env "fam" env with
        Vfam (_, fam, _, _) -> get_origin_file fam |> sou base |> Util.escape_html |> safe_val
      | _ -> null_val
    else raise Not_found
  | "qualifier" ->
    begin match get_env "qualifier" env with
        Vstring nn -> nn |> Util.escape_html |> safe_val
      | _ -> raise Not_found
    end
  | "related_type" ->
    begin match get_env "rel" env with
        Vrel (r, Some c) ->
        rchild_type_text conf r.r_type (index_of_sex (get_sex c))
        |> safe_val
      | _ -> raise Not_found
    end
  | "relation_type" ->
    begin match get_env "rel" env with
        Vrel (r, None) ->
        begin match r.r_fath, r.r_moth with
            Some _, None -> relation_type_text conf r.r_type 0 |> safe_val
          | None, Some _ -> relation_type_text conf r.r_type 1 |> safe_val
          | Some _, Some _ -> relation_type_text conf r.r_type 2 |> safe_val
          | _ -> raise Not_found
        end
      | _ -> raise Not_found
    end
  | "reset_count" ->
    begin match get_env "count" env with
        Vcnt c -> c := 0; null_val
      | _ -> null_val
    end
  | "reset_count1" ->
    begin match get_env "count1" env with
        Vcnt c -> c := 0; null_val
      | _ -> null_val
    end
  | "reset_count2" ->
    begin match get_env "count2" env with
        Vcnt c -> c := 0; null_val
      | _ -> null_val
    end
  | "reset_desc_level" ->
    let flevt_save =
      match get_env "desc_level_table_save" env with
        Vdesclevtab levt -> let (_, flevt) = Lazy.force levt in flevt
      | _ -> raise Not_found
    in
    begin match get_env "desc_level_table" env with
        Vdesclevtab levt ->
        let (_, flevt) = Lazy.force levt in
        Gwdb.Collection.iter (fun i ->
            Gwdb.Marker.set flevt i (Gwdb.Marker.get flevt_save i)
          ) (Gwdb.ifams base) ;
        null_val
      | _ -> raise Not_found
    end
  | "source_type" ->
    begin match get_env "src_typ" env with
        Vstring s -> s |> Util.safe_html |> safe_val
      | _ -> raise Not_found
    end
  | "surname_alias" ->
    begin match get_env "surname_alias" env with
        Vstring s -> s |> Util.safe_html |> safe_val
      | _ -> raise Not_found
    end
  | s ->
    let v = extract_var "evar_" s in
    if v <> "" then Util.escape_html v |> safe_val
    else raise Not_found
and eval_compound_var conf base env (a, _ as ep) loc =
  function
    "ancestor" :: sl ->
    begin match get_env "ancestor" env with
        Vanc gp -> eval_ancestor_field_var conf base env gp loc sl
      | Vanc_surn info -> eval_anc_by_surnl_field_var conf base env ep info sl
      | _ -> raise Not_found
    end
  | "baptism_witness" :: sl ->
    begin match get_env "baptism_witness" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | ["base"; "name"] -> VVstring conf.bname
  | ["base"; "nb_persons"] ->
    VVstring
      (Mutil.string_of_int_sep
         (Util.transl conf "(thousand separator)")
         (nb_of_persons base))
  | ["base"; "real_nb_persons"] ->
    VVstring
      (Mutil.string_of_int_sep
         (Util.transl conf "(thousand separator)")
         (Gwdb.nb_of_real_persons base))
  | "birth_witness" :: sl ->
    begin match get_env "birth_witness" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "burial_witness" :: sl ->
    begin match get_env "burial_witness" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "cell" :: sl ->
    begin match get_env "cell" env with
        Vcell cell -> eval_cell_field_var conf base env cell loc sl
      | _ -> raise Not_found
    end
  | "child" :: sl ->
    begin match get_env "child" env with
        Vind p when mode_local env ->
        let auth = authorized_age conf base p in
        let ep = p, auth in eval_person_field_var conf base env ep loc sl
      | _ ->
        match get_env "child_link" env with
          Vind p ->
          let ep = p, true in
          let baseprefix =
            match get_env "baseprefix" env with
              Vstring b -> b
            | _ -> conf.command
          in
          let conf = {conf with command = baseprefix} in
          eval_person_field_var conf base env ep loc sl
        | _ -> raise Not_found
    end
  | "cremation_witness" :: sl ->
    begin match get_env "cremation_witness" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "death_witness" :: sl ->
    begin match get_env "death_witness" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "enclosing" :: sl ->
    let rec loop =
      function
        ("#loop", _) :: env -> eval_person_field_var conf base env ep loc sl
      | _ :: env -> loop env
      | [] -> raise Not_found
    in
    loop env
  | "event_witness" :: sl ->
    begin match get_env "event_witness" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "event_witness_relation" :: sl ->
    begin match get_env "event_witness_relation" env with
        Vevent (p, e) ->
        eval_event_witness_relation_var conf base env (p, e) loc sl
      | _ -> raise Not_found
    end
  | "event_witness_relation_kind" :: _ ->
    begin match get_env "event_witness_relation_kind" env with
        Vstring wk -> VVstring wk
      | _ -> raise Not_found
    end
  | "event_witness_kind" :: _ ->
    begin match get_env "event_witness_kind" env with
        Vstring s -> VVstring s
      | _ -> raise Not_found
    end
  | "family" :: sl ->
    (* TODO ???
       let mode_local =
       match get_env "fam_link" env with
       [ Vfam ifam _ (_, _, ip) _ -> False
       | _ -> True ]
       in *)
    begin match get_env "fam" env with
        Vfam (i, f, c, m) ->
        eval_family_field_var conf base env (i, f, c, m) loc sl
      | _ ->
        match get_env "fam_link" env with
          Vfam (i, f, c, m) ->
          eval_family_field_var conf base env (i, f, c, m) loc sl
        | _ -> raise Not_found
    end
  | "father" :: sl ->
    begin match get_parents a with
        Some ifam ->
        let cpl = foi base ifam in
        let ep = make_ep conf base (get_father cpl) in
        eval_person_field_var conf base env ep loc sl
      | None ->
        match !GWPARAM_ITL.get_father conf base conf.command (get_iper a) with
        | Some (ep, base_prefix) ->
          let conf = {conf with command = base_prefix} in
          let env = ("p_link", Vbool true) :: env in
          eval_person_field_var conf base env ep loc sl
        | None ->
          warning_use_has_parents_before_parent loc "father" null_val
    end
  | "item" :: sl ->
    begin match get_env "item" env with
        Vslistlm ell -> eval_item_field_var ell sl
      | _ -> raise Not_found
    end
  | "mother" :: sl ->
    begin match get_parents a with
        Some ifam ->
        let cpl = foi base ifam in
        let ep = make_ep conf base (get_mother cpl) in
        eval_person_field_var conf base env ep loc sl
      | None ->
        match !GWPARAM_ITL.get_mother conf base conf.command (get_iper a) with
        | Some (ep, base_prefix) ->
          let conf = {conf with command = base_prefix} in
          let env = ("p_link", Vbool true) :: env in
          eval_person_field_var conf base env ep loc sl
        | None ->
          warning_use_has_parents_before_parent loc "mother" null_val
    end
  | "next_item" :: sl ->
    begin match get_env "item" env with
        Vslistlm (_ :: ell) -> eval_item_field_var ell sl
      | _ -> raise Not_found
    end
  | "number_of_ancestors" :: sl ->
    begin match get_env "n" env with
        Vint n -> VVstring (eval_num conf (Sosa.of_int (n - 1)) sl)
      | _ -> raise Not_found
    end
  | "number_of_descendants" :: sl ->
    (* FIXME: what is the difference with number_of_descendants_at_level??? *)
    begin match get_env "level" env with
        Vint i ->
        begin match get_env "desc_level_table" env with
            Vdesclevtab t ->
            let m = fst (Lazy.force t) in
            let cnt =
              Gwdb.Collection.fold (fun cnt ip ->
                  if Gwdb.Marker.get m ip <= i then cnt + 1 else cnt
                ) 0 (Gwdb.ipers base)
            in
            VVstring (eval_num conf (Sosa.of_int (cnt - 1)) sl)
          | _ -> raise Not_found
        end
      | _ -> raise Not_found
    end
  | "number_of_descendants_at_level" :: sl ->
    begin match get_env "level" env with
        Vint i ->
        begin match get_env "desc_level_table" env with
            Vdesclevtab t ->
            let m = fst (Lazy.force t) in
            let cnt =
              Gwdb.Collection.fold (fun cnt ip ->
                  if Gwdb.Marker.get m ip <= i then cnt + 1 else cnt
                ) 0 (Gwdb.ipers base)
            in
            VVstring (eval_num conf (Sosa.of_int (cnt - 1)) sl)
          | _ -> raise Not_found
        end
      | _ -> raise Not_found
    end
  | "parent" :: sl ->
    begin match get_env "parent" env with
        Vind p ->
        let ep = p, authorized_age conf base p in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "prev_item" :: sl ->
    begin match get_env "prev_item" env with
        Vslistlm ell -> eval_item_field_var ell sl
      | _ -> raise Not_found
    end
  | "prev_family" :: sl ->
    begin match get_env "prev_fam" env with
        Vfam (i, f, c, m) ->
        eval_family_field_var conf base env (i, f, c, m) loc sl
      | _ -> raise Not_found
    end
  | "pvar" :: v :: sl ->
    begin match find_person_in_env conf base v with
      | Some p ->
        let ep = make_ep conf base (get_iper p) in
        eval_person_field_var conf base env ep loc sl
      | None -> raise Not_found
    end
  | "qvar" :: v :: sl ->
    (* %qvar.index_v.surname;
       direct access to a person whose index value is v
    *)
    let v0 = iper_of_string v in
    (* if v0 >= 0 && v0 < nb_of_persons base then *)
    let ep = make_ep conf base v0 in
    if is_hidden (fst ep) then raise Not_found
    else eval_person_field_var conf base env ep loc sl
  (* else raise Not_found *)
  | "svar" :: i :: sl ->
    (* http://localhost:2317/HenriT_w?m=DAG&p1=henri&n1=duchmol&s1=243&s2=245
       access to sosa si=n of a person pi ni
       find_base_p will scan down starting from i such that multiple sosa of
       the same person can be listed
    *)
    let rec find_base_p j =
      let s = string_of_int j in
      let po = Util.find_person_in_env conf base s in
      begin match po with
        | Some p -> p
        | None -> if j = 0 then raise Not_found else find_base_p (j-1)
      end
    in
    let p0 = find_base_p (int_of_string i) in
    (* find sosa identified by si= of that person *)
    begin match p_getint conf.env ("s" ^ i) with
      | Some s ->
        let s0 = Sosa.of_int s in
        let ip0 = get_iper p0 in
        begin match Util.branch_of_sosa conf base s0 (pget conf base ip0) with
          | Some (p :: _) ->
            let p_auth = authorized_age conf base p in
            eval_person_field_var conf base env (p, p_auth) loc sl
          | _ -> raise Not_found
        end
      | None -> raise Not_found
    end
  | "sosa_anc" :: s :: sl ->
    (* %sosa_anc.sosa.first_name;
       direct access to a person whose sosa relative to sosa_ref is s
    *)
    begin match get_env "sosa_ref" env with
      | Vsosa_ref (Some p) ->
        let ip = get_iper p in
        let s0 = Sosa.of_string s in
        begin match Util.branch_of_sosa conf base s0 (pget conf base ip) with
          | Some (p :: _) ->
            let p_auth = authorized_age conf base p in
            eval_person_field_var conf base env (p, p_auth) loc sl
          | _ -> raise Not_found
        end
      | _ -> raise Not_found
    end
  | "sosa_anc_p" :: s :: sl ->
    (* %sosa_anc_p.sosa.first_name;
       direct access to a person whose sosa relative to current person
    *)
    begin match Util.p_of_sosa conf base (Sosa.of_string s) a with
      | Some np ->
        let np_auth = authorized_age conf base np in
        eval_person_field_var conf base env (np, np_auth) loc sl
      | _ -> raise Not_found
    end
  | "related" :: sl ->
    begin match get_env "rel" env with
        Vrel ({r_type = rt}, Some p) ->
        eval_relation_field_var conf base env
          (index_of_sex (get_sex p), rt, get_iper p, false) loc sl
      | _ -> raise Not_found
    end
  | "relation_her" :: sl ->
    begin match get_env "rel" env with
        Vrel ({r_moth = Some ip; r_type = rt}, None) ->
        eval_relation_field_var conf base env (1, rt, ip, true) loc sl
      | _ -> raise Not_found
    end
  | "relation_him" :: sl ->
    begin match get_env "rel" env with
        Vrel ({r_fath = Some ip; r_type = rt}, None) ->
        eval_relation_field_var conf base env (0, rt, ip, true) loc sl
      | _ -> raise Not_found
    end
  | "self" :: sl -> eval_person_field_var conf base env ep loc sl
  | "sosa_ref" :: sl ->
    begin match get_env "sosa_ref" env with
      | Vsosa_ref (Some p) ->
        let ep = make_ep conf base (get_iper p) in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
    end
  | "spouse" :: sl ->
     begin match get_env "fam" env with
       Vfam (_, _, (_, _, ip), _) when mode_local env ->
        let ep = make_ep conf base ip in
        eval_person_field_var conf base env ep loc sl
     | _ ->
        match get_env "fam_link" env with
          Vfam (_, _, (_, _, ip), _) ->
           let baseprefix =
             match get_env "baseprefix" env with
               Vstring baseprefix -> baseprefix
             | _ -> conf.command
           in
           begin match !GWPARAM_ITL.get_person conf base baseprefix ip with
           | Some (ep, baseprefix) ->
              let conf = { conf with command = baseprefix } in
              let env = ("p_link", Vbool true) :: env in
              eval_person_field_var conf base env ep loc sl
           | None -> raise Not_found
           end
        | _ -> raise Not_found
     end
| "witness" :: sl ->
  begin match get_env "witness" env with
      Vind p ->
      let ep = p, authorized_age conf base p in
      eval_person_field_var conf base env ep loc sl
    | _ -> raise Not_found
  end
| "witness_relation" :: sl ->
  begin match get_env "fam" env with
      Vfam (i, f, c, m) ->
      eval_witness_relation_var conf base env (i, f, c, m) loc sl
    | _ -> raise Not_found
  end
| sl -> eval_person_field_var conf base env ep loc sl
and eval_item_field_var ell =
    function
      [s] ->
      begin try
          match ell with
            el :: _ ->
            let v = int_of_string s in
            let r = try List.nth el (v - 1) with Failure _ -> "" in VVstring r
          | [] -> null_val
        with Failure _ -> raise Not_found
      end
    | _ -> raise Not_found
and eval_relation_field_var conf base env (i, rt, ip, is_relation) loc =
    function
      ["type"] ->
      if is_relation then safe_val (relation_type_text conf rt i)
      else safe_val (rchild_type_text conf rt i)
    | sl ->
      let ep = make_ep conf base ip in
      eval_person_field_var conf base env ep loc sl
and eval_cell_field_var conf base env cell loc =
    function
      ["colspan"] ->
      begin match cell with
          Empty -> VVstring "1"
        | Cell (_, _, _, _, s, _) -> VVstring (string_of_int s)
      end
    | "family" :: sl ->
      begin match cell with
          Cell (p, Some ifam, _, _, _, base_prefix) ->
          if conf.bname = base_prefix then
            let (f, c, a) = make_efam conf base (get_iper p) ifam in
            eval_family_field_var conf base env (ifam, f, c, a) loc sl
          else begin
            let conf = {conf with command = base_prefix} in
            match !GWPARAM_ITL.get_family conf base base_prefix p ifam with
            | Some (f, c, a) ->
              eval_family_field_var conf base env (ifam, f, c, a) loc sl
            | None -> assert false
          end
      | _ -> VVstring ""
      end
    | ["is_center"] ->
      begin match cell with
          Cell (_, _, Center, _, _, _) -> VVbool true
        | _ -> VVbool false
      end
    | ["is_empty"] ->
      begin match cell with
          Empty -> VVbool true
        | _ -> VVbool false
      end
    | ["is_left"] ->
      begin match cell with
          Cell (_, _, Left, _, _, _) -> VVbool true
        | _ -> VVbool false
      end
    | ["is_right"] ->
      begin match cell with
          Cell (_, _, Right, _, _, _) -> VVbool true
        | _ -> VVbool false
      end
    | ["is_top"] ->
      begin match cell with
          Cell (_, _, _, false, _, _) -> VVbool true
        | _ -> VVbool false
      end
    | "person" :: sl ->
      begin match cell with
          Cell (p, _, _, _, _, base_prefix) ->
          if conf.bname = base_prefix then
            let ep = make_ep conf base (get_iper p) in
            eval_person_field_var conf base env ep loc sl
          else
            let conf = {conf with command = base_prefix} in
            let ep = p, true in eval_person_field_var conf base env ep loc sl
        | _ -> raise Not_found
      end
    | _ -> raise Not_found
and eval_ancestor_field_var conf base env gp loc =
    function
      "family" :: sl ->
      begin match gp with
          GP_person (_, ip, Some ifam) ->
          let f = foi base ifam in
          let ifath = get_father f in
          let imoth = get_mother f in
          let ispouse = if ip = ifath then imoth else ifath in
          let c = ifath, imoth, ispouse in
          let m_auth =
            authorized_age conf base (pget conf base ifath) &&
            authorized_age conf base (pget conf base imoth)
          in
          eval_family_field_var conf base env (ifam, f, c, m_auth) loc sl
        | _ -> raise Not_found
      end
    | "father" :: sl ->
      begin match gp with
          GP_person (_, ip, _) ->
          begin match
              get_parents (pget conf base ip), get_env "all_gp" env
            with
              Some ifam, Vallgp all_gp ->
              let cpl = foi base ifam in
              begin match get_link all_gp (get_father cpl) with
                  Some gp -> eval_ancestor_field_var conf base env gp loc sl
                | None ->
                  let ep = make_ep conf base (get_father cpl) in
                  eval_person_field_var conf base env ep loc sl
              end
            | _, _ -> raise Not_found
          end
        | GP_same (_, _, ip) ->
          begin match get_parents (pget conf base ip) with
              Some ifam ->
              let cpl = foi base ifam in
              let ep = make_ep conf base (get_father cpl) in
              eval_person_field_var conf base env ep loc sl
            | _ -> raise Not_found
          end
        | _ -> raise Not_found
      end
    | ["father_sosa"] ->
      begin match gp, get_env "all_gp" env with
          (GP_person (n, ip, _) | GP_same (n, _, ip)), Vallgp all_gp ->
          let n = Sosa.twice n in
          VVstring (parent_sosa conf base ip all_gp n get_father)
        | _ -> null_val
      end
    | ["interval"] ->
      let to_string x =
        Mutil.string_of_int_sep
          (transl conf "(thousand separator)")
          (int_of_string @@ Sosa.to_string x)
      in
      begin match gp with
          GP_interv (Some (n1, n2, Some (n3, n4))) ->
          let n2 = Sosa.sub n2 Sosa.one in
          let n4 = Sosa.sub n4 Sosa.one in
          VVstring (to_string n1 ^ "-" ^ to_string n2 ^ " = " ^ to_string n3 ^ "-" ^ to_string n4)
        | GP_interv (Some (n1, n2, None)) ->
          let n2 = Sosa.sub n2 Sosa.one in
          VVstring (to_string n1 ^ "-" ^ to_string n2 ^ " = ...")
        | GP_interv None -> VVstring "..."
        | _ -> null_val
      end
    | ["mother_sosa"] ->
      begin match gp, get_env "all_gp" env with
          (GP_person (n, ip, _) | GP_same (n, _, ip)), Vallgp all_gp ->
          let n = Sosa.inc (Sosa.twice n) 1 in
          VVstring (parent_sosa conf base ip all_gp n get_mother)
        | _ -> null_val
      end
    | "same" :: sl ->
      begin match gp with
          GP_same (_, n, _) -> VVstring (eval_num conf n sl)
        | _ -> null_val
      end
    | "anc_sosa" :: sl ->
      begin match gp with
          GP_person (n, _, _) | GP_same (n, _, _) ->
          VVstring (eval_num conf n sl)
        | _ -> null_val
      end
    | "spouse" :: sl ->
      begin match gp with
          GP_person (_, ip, Some ifam) ->
          let ip = Gutil.spouse ip (foi base ifam) in
          let ep = make_ep conf base ip in
          eval_person_field_var conf base env ep loc sl
        | _ -> raise Not_found
      end
    | sl ->
      match gp with
        GP_person (_, ip, _) | GP_same (_, _, ip) ->
        let ep = make_ep conf base ip in
        eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
and eval_anc_by_surnl_field_var conf base env ep info =
    match info with
      Branch (_, db, de, place, p, sosa_list, loc) ->
      (function
          "date_begin" :: sl ->
          begin match db with
              Some d -> eval_date_field_var conf d sl
            | None -> null_val
          end
        | "date_end" :: sl ->
          begin match de with
              Some d -> eval_date_field_var conf d sl
            | None -> null_val
          end
        | ["nb_times"] -> str_val (string_of_int (List.length sosa_list))
        | ["place"] -> safe_val (Util.string_of_place conf place)
        | ["sosa_access"] ->
          let (str, _) =
            List.fold_right begin fun sosa (str, n) ->
              str ^^^ "&s" ^<^ string_of_int n ^<^ "=" ^<^ (Sosa.to_string sosa |> Mutil.encode)
            , n + 1
            end sosa_list (Adef.encoded "", 1)
          in
          let (p, _) = ep in
          safe_val
            ( (acces_n conf base (Adef.escaped "1") p : Adef.escaped_string :> Adef.safe_string)
              ^^^ (str : Adef.encoded_string :> Adef.safe_string) )
        | sl ->
          let ep = make_ep conf base (get_iper p) in
          eval_person_field_var conf base env ep loc sl)
    | Eclair (_, place, db, de, p, persl, loc) ->
      function
        "date_begin" :: sl ->
        begin match db with
            Some d -> eval_date_field_var conf d sl
          | None -> null_val
        end
      | "date_end" :: sl ->
        begin match de with
            Some d -> eval_date_field_var conf d sl
          | None -> null_val
        end
      | ["nb_events"] -> VVstring (string_of_int (List.length persl))
      | ["nb_ind"] ->
        IperSet.elements (List.fold_right IperSet.add persl IperSet.empty)
        |> List.length
        |> string_of_int
        |> str_val
      | ["place"] -> safe_val place
      | sl ->
        let ep = make_ep conf base (get_iper p) in
        eval_person_field_var conf base env ep loc sl
and eval_num conf n =
  function
    ["hexa"] -> Printf.sprintf "0x%X" @@ int_of_string (Sosa.to_string n)
  | ["octal"] -> Printf.sprintf "0x%o" @@ int_of_string (Sosa.to_string n)
  | ["lvl"] -> string_of_int @@ Sosa.gen n
  | ["v"] -> Sosa.to_string n
  | [] -> Sosa.to_string_sep (transl conf "(thousand separator)") n
  | _ -> raise Not_found
and eval_person_field_var conf base env (p, p_auth as ep) loc =
  function
    "baptism_date" :: sl ->
      begin match Adef.od_of_cdate (get_baptism p) with
        Some d when p_auth -> eval_date_field_var conf d sl
      | _ -> null_val
      end
  | "birth_date" :: sl ->
      begin match Adef.od_of_cdate (get_birth p) with
        Some d when p_auth -> eval_date_field_var conf d sl
      | _ -> null_val
      end
  | "burial_date" :: sl ->
      begin match get_burial p with
        Buried cod when p_auth ->
          begin match Adef.od_of_cdate cod with
            Some d -> eval_date_field_var conf d sl
          | None -> null_val
          end
      | _ -> null_val
      end
  | "cremated_date" :: sl ->
      begin match get_burial p with
        Cremated cod when p_auth ->
          begin match Adef.od_of_cdate cod with
            Some d -> eval_date_field_var conf d sl
          | None -> null_val
          end
      | _ -> null_val
      end
  | "death_date" :: sl ->
      begin match get_death p with
        Death (_, cd) when p_auth ->
          eval_date_field_var conf (Adef.date_of_cdate cd) sl
      | _ -> null_val
      end
  | "event" :: sl ->
      begin match get_env "event" env with
        Vevent (_, e) -> eval_event_field_var conf base env ep e loc sl
      | _ -> raise Not_found
      end
  | "father" :: sl ->
      begin match get_parents p with
        Some ifam ->
          let cpl = foi base ifam in
          let ep = make_ep conf base (get_father cpl) in
          eval_person_field_var conf base env ep loc sl
        | None ->
          match !GWPARAM_ITL.get_father conf base conf.command (get_iper p) with
          | Some (ep, baseprefix) ->
            let conf = {conf with command = baseprefix} in
            let env = ("p_link", Vbool true) :: env in
            eval_person_field_var conf base env ep loc sl
          | None ->
            warning_use_has_parents_before_parent loc "father" null_val
      end
  | ["has_linked_page"; s] ->
      begin match get_env "nldb" env with
        Vnldb db ->
          let key =
            let fn = Name.lower (sou base (get_first_name p)) in
            let sn = Name.lower (sou base (get_surname p)) in
            fn, sn, get_occ p
          in
          let r =
            List.exists
              (fun (pg, (_, il)) ->
                 match pg with
                   Def.NLDB.PgMisc pg ->
                     if List.mem_assoc key il then
                       let (nenv, _) = Notes.read_notes base pg in
                       List.mem_assoc s nenv
                     else false
                 | _ -> false)
              db
          in
          VVbool r
      | _ -> raise Not_found
      end
  | ["has_linked_pages"] ->
      begin match get_env "nldb" env with
        Vnldb db ->
          let r =
            if p_auth then
              let key =
                let fn = Name.lower (sou base (get_first_name p)) in
                let sn = Name.lower (sou base (get_surname p)) in
                fn, sn, get_occ p
              in
              links_to_ind conf base db key <> []
            else false
          in
          VVbool r
      | _ -> raise Not_found
      end
  | ["has_sosa"] ->
      begin match get_env "p_link" env with
        Vbool _ -> VVbool false
      | _ ->
          match get_env "sosa" env with
            Vsosa r -> VVbool (get_sosa conf base env r p <> None)
          | _ -> VVbool false
      end
  | ["init_cache"; nb_asc; from_gen_desc; nb_desc] ->
      begin try
        let nb_asc = int_of_string nb_asc in
        let from_gen_desc = int_of_string from_gen_desc in
        let nb_desc = int_of_string nb_desc in
        let () =  !GWPARAM_ITL.init_cache conf base (get_iper p) nb_asc from_gen_desc nb_desc in
        null_val
      with _ -> raise Not_found
      end
  | ["linked_page"; s] ->
      begin match get_env "nldb" env with
        Vnldb db ->
          let key =
            let fn = Name.lower (sou base (get_first_name p)) in
            let sn = Name.lower (sou base (get_surname p)) in
            fn, sn, get_occ p
          in
          List.fold_left (linked_page_text conf base p s key) (Adef.safe "") db
          |> safe_val
      | _ -> raise Not_found
      end
  | "marriage_date" :: sl ->
      begin match get_env "fam" env with
        Vfam (_, fam, _, true) ->
          begin match Adef.od_of_cdate (get_marriage fam) with
            Some d -> eval_date_field_var conf d sl
          | None -> null_val
          end
      | _ -> raise Not_found
      end
  | "mother" :: sl ->
      begin match get_parents p with
        Some ifam ->
          let cpl = foi base ifam in
          let ep = make_ep conf base (get_mother cpl) in
          eval_person_field_var conf base env ep loc sl
      | None ->
        match !GWPARAM_ITL.get_mother conf base conf.command (get_iper p) with
        | Some (ep, baseprefix) ->
          let conf = {conf with command = baseprefix} in
          let env = ("p_link", Vbool true) :: env in
          eval_person_field_var conf base env ep loc sl
        | None ->
          warning_use_has_parents_before_parent loc "mother" null_val
      end
  | "nobility_title" :: sl ->
      begin match Util.main_title conf base p with
        Some t when p_auth ->
          let id = sou base t.t_ident in
          let pl = sou base t.t_place in
          eval_nobility_title_field_var (id, pl) sl
      | _ -> null_val
      end
  | "self" :: sl -> eval_person_field_var conf base env ep loc sl
  | "sosa" :: sl ->
      begin match get_env "sosa" env with
        Vsosa x ->
          begin match get_sosa conf base env x p with
            Some (n, _) -> VVstring (eval_num conf n sl)
          | None -> null_val
          end
      | _ -> raise Not_found
      end
  | "sosa_next" :: sl ->
      begin match get_env "sosa" env with
      | Vsosa x ->
          begin match get_sosa conf base env x p with
          | Some (n, _) ->
              begin match next_sosa n with
              | (so, ip) ->
                if so = Sosa.zero then null_val
                else
                  let p = poi base ip in
                  let p_auth = authorized_age conf base p in
                  eval_person_field_var conf base env (p, p_auth) loc sl
              end
          | None -> null_val
          end
      | _ -> raise Not_found
      end
  | "sosa_prev" :: sl ->
      begin match get_env "sosa" env with
      | Vsosa x ->
          begin match get_sosa conf base env x p with
          | Some (n, _) ->
              begin match prev_sosa n with
              | (so, ip) ->
                if Sosa.eq so Sosa.zero then null_val
                else
                  let p = poi base ip in
                  let p_auth = authorized_age conf base p in
                  eval_person_field_var conf base env (p, p_auth) loc sl
              end
          | None -> null_val
          end
      | _ -> raise Not_found
      end
  | "spouse" :: sl ->
      begin match get_env "fam" env with
        Vfam (ifam, _, _, _) ->
          let cpl = foi base ifam in
          let ip = Gutil.spouse (get_iper p) cpl in
          let ep = make_ep conf base ip in
          eval_person_field_var conf base env ep loc sl
      | _ -> raise Not_found
      end
  | ["var"] -> VVother (eval_person_field_var conf base env ep loc)
  | [s] ->
      begin
        try bool_val (eval_bool_person_field conf base env ep s)
        with Not_found -> eval_str_person_field conf base env ep s
      end
  | [] -> simple_person_text conf base p p_auth |> safe_val
  | _ -> raise Not_found
and eval_date_field_var conf d =
  function
    ["prec"] ->
      begin match d with
        Dgreg (dmy, _) -> DateDisplay.prec_text conf dmy |> Util.escape_html |> safe_val
      | _ -> null_val
      end
  | ["day"] ->
      begin match d with
        Dgreg (dmy, _) ->
          if dmy.day = 0 then null_val
          else VVstring (string_of_int dmy.day)
      | _ -> null_val
      end
  | ["day2"] ->
      begin match d with
        Dgreg (dmy, _) ->
          begin match dmy.prec with
            OrYear dmy2 | YearInt dmy2 ->
              if dmy2.day2 = 0 then null_val
              else VVstring (string_of_int dmy2.day2)
          | _ -> null_val
          end
      | _ -> null_val
      end
  | ["julian_day"] ->
      begin match d with
        Dgreg (dmy, _) ->
          VVstring (string_of_int (Calendar.sdn_of_julian dmy))
      | _ -> null_val
      end
  | ["month"] ->
      begin match d with
        Dgreg (dmy, _) -> VVstring (DateDisplay.month_text dmy)
      | _ -> null_val
      end
  | ["month2"] ->
      begin match d with
        Dgreg (dmy, _) ->
          begin match dmy.prec with
            OrYear dmy2 | YearInt dmy2 ->
              if dmy2.month2 = 0 then null_val
              else VVstring (string_of_int dmy2.month2)
          | _ -> null_val
          end
      | _ -> null_val
      end
  | ["year"] ->
      begin match d with
        Dgreg (dmy, _) -> VVstring (string_of_int dmy.year)
      | _ -> null_val
      end
  | ["year2"] ->
      begin match d with
        Dgreg (dmy, _) ->
          begin match dmy.prec with
            OrYear dmy2 | YearInt dmy2 -> VVstring (string_of_int dmy2.year2)
          | _ -> null_val
          end
      | _ -> null_val
      end
  | [] ->
    DateDisplay.string_of_date_aux ~link:false conf ~sep:(Adef.safe "&#010;  ") d
    |> safe_val
  | _ -> raise Not_found
and _eval_place_field_var conf place =
  function
    [] ->
      (* Compatibility before eval_place_field_var *)
      VVstring place
  | ["other"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.other
      | None -> null_val
      end
  | ["town"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.town
      | None -> null_val
      end
  | ["township"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.township
      | None -> null_val
      end
  | ["canton"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.canton
      | None -> null_val
      end
  | ["district"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.district
      | None -> null_val
      end
  | ["county"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.county
      | None -> null_val
      end
  | ["region"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.region
      | None -> null_val
      end
  | ["country"] ->
      begin match place_of_string conf place with
        Some p -> VVstring p.country
      | None -> null_val
      end
  | _ -> raise Not_found
and eval_nobility_title_field_var (id, pl) =
  function
    ["ident_key"] -> safe_val (Mutil.encode id)
  | ["place_key"] -> safe_val (Mutil.encode pl)
  | [] -> VVstring (if pl = "" then id else id ^ " " ^ pl)
  | _ -> raise Not_found
and eval_bool_event_field base (p, p_auth)
    (_, date, place, note, src, w, isp) =
  function
    "has_date" -> p_auth && date <> Adef.cdate_None
  | "has_place" -> p_auth && sou base place <> ""
  | "has_note" -> p_auth && sou base note <> ""
  | "has_src" -> p_auth && sou base src <> ""
  | "has_witnesses" -> p_auth && Array.length w > 0
  | "has_spouse" -> p_auth && isp <> None
  | "computable_age" ->
      if p_auth then
        match Adef.od_of_cdate (get_birth p) with
          Some (Dgreg (d, _)) ->
            not (d.day = 0 && d.month = 0 && d.prec <> Sure)
        | _ ->
            match Adef.od_of_cdate (get_baptism p) with
              Some (Dgreg (d, _)) ->
                not (d.day = 0 && d.month = 0 && d.prec <> Sure)
            | _ -> false
      else false
  | _ -> raise Not_found
and eval_str_event_field conf base (p, p_auth)
    (name, date, place, note, src, _, _) =
  function
    "age" ->
      if p_auth then
        let (birth_date, approx) =
          match Adef.od_of_cdate (get_birth p) with
            None -> Adef.od_of_cdate (get_baptism p), true
          | x -> x, false
        in
        match birth_date, Adef.od_of_cdate date with
          Some (Dgreg (({prec = Sure | About | Maybe} as d1), _)),
          Some (Dgreg (({prec = Sure | About | Maybe} as d2), _))
          when d1 <> d2 ->
            let a = Date.time_elapsed d1 d2 in
            let s =
              if not approx && d1.prec = Sure && d2.prec = Sure then ""
              else transl_decline conf "possibly (date)" "" ^ " "
            in
            safe_val (s ^<^ DateDisplay.string_of_age conf a)
        | _ -> null_val
      else null_val
  | "name" ->
      begin match p_auth, name with
        true, Pevent name -> Util.string_of_pevent_name conf base name |> safe_val
      | true, Fevent name -> Util.string_of_fevent_name conf base name |> safe_val
      | _ -> null_val
      end
  | "date" ->
      begin match p_auth, Adef.od_of_cdate date with
        true, Some d -> DateDisplay.string_of_date conf d |> safe_val
      | _ -> null_val
      end
  | "on_date" ->
    date_aux conf p_auth date
  | "place" ->
      if p_auth
      then
        sou base place
        |> Util.string_of_place conf
        |> safe_val
      else null_val
  | "note" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      sou base note
      |> get_note_source conf base env p_auth conf.no_note
      |> safe_val
  | "src" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      sou base src
      |> get_note_source conf base env p_auth false
      |> safe_val
  | _ -> raise Not_found
and eval_event_field_var conf base env (p, p_auth)
    (name, date, place, note, src, w, isp) loc =
  function
    "date" :: sl ->
      begin match p_auth, Adef.od_of_cdate date with
        true, Some d -> eval_date_field_var conf d sl
      | _ -> null_val
      end
  | "spouse" :: sl ->
      begin match isp with
        Some isp ->
          let sp = poi base isp in
          let ep = sp, authorized_age conf base sp in
          eval_person_field_var conf base env ep loc sl
      | None -> null_val
      end
  | [s] ->
      begin try
        bool_val
          (eval_bool_event_field base (p, p_auth)
             (name, date, place, note, src, w, isp) s)
      with Not_found ->
        eval_str_event_field conf base (p, p_auth) (name, date, place, note, src, w, isp) s
      end
  | _ -> raise Not_found
and eval_event_witness_relation_var conf base env (p, e) loc =
  function
    "event" :: sl ->
      let ep = p, authorized_age conf base p in
      eval_event_field_var conf base env ep e loc sl
  | "person" :: sl ->
      let ep = p, authorized_age conf base p in
      eval_person_field_var conf base env ep loc sl
  | _ -> raise Not_found
and eval_bool_person_field conf base env (p, p_auth) =
  function
    "access_by_key" ->
      Util.accessible_by_key conf base p (p_first_name base p)
        (p_surname base p)
  | "birthday" ->
      begin match p_auth, Adef.od_of_cdate (get_birth p) with
        true, Some (Dgreg (d, _)) ->
          if d.prec = Sure && get_death p = NotDead then
            d.day = conf.today.day && d.month = conf.today.month &&
            d.year < conf.today.year ||
            not (Date.leap_year conf.today.year) && d.day = 29 &&
            d.month = 2 && conf.today.day = 1 && conf.today.month = 3
          else false
      | _ -> false
      end
  | "wedding_birthday" ->
      begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
          begin match get_relation fam, get_divorce fam with
            (Married | NoSexesCheckMarried), NotDivorced ->
              begin match m_auth, Adef.od_of_cdate (get_marriage fam) with
                true, Some (Dgreg (d, _)) ->
                  let father = pget conf base (get_father fam) in
                  let mother = pget conf base (get_mother fam) in
                  if d.prec = Sure && authorized_age conf base father &&
                     get_death father = NotDead &&
                     authorized_age conf base mother &&
                     get_death mother = NotDead
                  then
                    d.day = conf.today.day && d.month = conf.today.month &&
                    d.year < conf.today.year ||
                    not (Date.leap_year conf.today.year) && d.day = 29 &&
                    d.month = 2 && conf.today.day = 1 && conf.today.month = 3
                  else false
              | _ -> false
              end
          | _ -> false
          end
      | _ -> false
      end
  | "computable_age" ->
      if p_auth then
        match Adef.od_of_cdate (get_birth p), get_death p with
          Some (Dgreg (d, _)), NotDead ->
            not (d.day = 0 && d.month = 0 && d.prec <> Sure)
        | _ -> false
      else false
  | "computable_death_age" ->
      if p_auth then
        match Gutil.get_birth_death_date p with
          Some (Dgreg (({prec = Sure | About | Maybe} as d1), _)),
          Some (Dgreg (({prec = Sure | About | Maybe} as d2), _)),
          _
          when d1 <> d2 ->
            let a = Date.time_elapsed d1 d2 in
            a.year > 0 ||
            a.year = 0 && (a.month > 0 || a.month = 0 && a.day > 0)
        | _ -> false
      else false
  | "computable_marriage_age" ->
      begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
          if m_auth then
            match
              Adef.od_of_cdate (get_birth p),
              Adef.od_of_cdate (get_marriage fam)
            with
              Some (Dgreg (({prec = Sure | About | Maybe} as d1), _)),
              Some (Dgreg (({prec = Sure | About | Maybe} as d2), _)) ->
                let a = Date.time_elapsed d1 d2 in
                a.year > 0 ||
                a.year = 0 && (a.month > 0 || a.month = 0 && a.day > 0)
            | _ -> false
          else false
      | _ -> raise Not_found
      end
  | "has_approx_birth_date" ->
      p_auth && fst (Util.get_approx_birth_date_place conf base p) <> None
  | "has_approx_birth_place" ->
      p_auth && (snd (Util.get_approx_birth_date_place conf base p) :> string) <> ""
  | "has_approx_death_date" ->
      p_auth && fst (Util.get_approx_death_date_place conf base p) <> None
  | "has_approx_death_place" ->
      p_auth && (snd (Util.get_approx_death_date_place conf base p) :> string) <> ""
  | "has_aliases" ->
      if not p_auth && is_hide_names conf p then false
      else get_aliases p <> []
  | "has_baptism_date" -> p_auth && get_baptism p <> Adef.cdate_None
  | "has_baptism_place" -> p_auth && sou base (get_baptism_place p) <> ""
  | "has_baptism_source" -> p_auth && sou base (get_baptism_src p) <> ""
  | "has_baptism_note" ->
      p_auth && not conf.no_note && sou base (get_baptism_note p) <> ""
  | "has_baptism_witnesses" ->
      let rec loop pevents =
        match pevents with
          [] -> false
        | (name, _, _, _, _, wl, _) :: events ->
            if name = Pevent Epers_Baptism then Array.length wl > 0
            else loop events
      in
      p_auth && loop (events_list conf base p)
  | "has_birth_date" -> p_auth && get_birth p <> Adef.cdate_None
  | "has_birth_place" -> p_auth && sou base (get_birth_place p) <> ""
  | "has_birth_source" -> p_auth && sou base (get_birth_src p) <> ""
  | "has_birth_note" ->
      p_auth && not conf.no_note && sou base (get_birth_note p) <> ""
  | "has_birth_witnesses" ->
      let rec loop pevents =
        match pevents with
          [] -> false
        | (name, _, _, _, _, wl, _) :: events ->
            if name = Pevent Epers_Birth then Array.length wl > 0
            else loop events
      in
      p_auth && loop (events_list conf base p)
  | "has_burial_date" ->
      if p_auth then
        match get_burial p with
          Buried cod -> Adef.od_of_cdate cod <> None
        | _ -> false
      else false
  | "has_burial_place" -> p_auth && sou base (get_burial_place p) <> ""
  | "has_burial_source" -> p_auth && sou base (get_burial_src p) <> ""
  | "has_burial_note" ->
      p_auth && not conf.no_note && sou base (get_burial_note p) <> ""
  | "has_burial_witnesses" ->
      let rec loop pevents =
        match pevents with
          [] -> false
        | (name, _, _, _, _, wl, _) :: events ->
            if name = Pevent Epers_Burial then Array.length wl > 0
            else loop events
      in
      p_auth && loop (events_list conf base p)
  | "has_children" ->
      begin match get_env "fam" env with
        Vfam (_, fam, _, _) ->
          if Array.length (get_children fam) > 0 then true
          else !GWPARAM_ITL.has_children conf base p fam
      | _ ->
        Array.exists (fun ifam -> [||] <> get_children (foi base ifam)) (get_family p)
        || begin match get_env "fam_link" env with
          | Vfam (ifam, _, (ifath, imoth, _), _) ->
            let conf =
              match get_env "baseprefix" env with
              | Vstring baseprefix -> {conf with command = baseprefix}
              | _ -> conf
            in
            [] <> !GWPARAM_ITL.get_children_of_parents base conf.command ifam ifath imoth
          | _ -> false
        end
      end
  | "has_consanguinity" ->
      p_auth && get_consang p != Adef.fix (-1) &&
      get_consang p >= Adef.fix_of_float 0.0001
  | "has_cremation_date" ->
      if p_auth then
        match get_burial p with
          Cremated cod -> Adef.od_of_cdate cod <> None
        | _ -> false
      else false
  | "has_cremation_place" -> p_auth && sou base (get_burial_place p) <> ""
  | "has_cremation_witnesses" ->
      let rec loop pevents =
        match pevents with
          [] -> false
        | (name, _, _, _, _, wl, _) :: events ->
            if name = Pevent Epers_Cremation then Array.length wl > 0
            else loop events
      in
      p_auth && loop (events_list conf base p)
  | "has_death_date" ->
      begin match get_death p with
        Death (_, _) -> p_auth
      | _ -> false
      end
  | "has_death_place" -> p_auth && sou base (get_death_place p) <> ""
  | "has_death_source" -> p_auth && sou base (get_death_src p) <> ""
  | "has_death_note" ->
      p_auth && not conf.no_note && sou base (get_death_note p) <> ""
  | "has_death_witnesses" ->
      let rec loop pevents =
        match pevents with
          [] -> false
        | (name, _, _, _, _, wl, _) :: events ->
            if name = Pevent Epers_Death then Array.length wl > 0
            else loop events
      in
      p_auth && loop (events_list conf base p)
  | "has_event" ->
      if p_auth then
        let events = events_list conf base p in
        let nb_fam = Array.length (get_family p) in
        match List.assoc_opt "has_events" conf.base_env with
        | Some "never" -> false
        | Some "always" ->
          if nb_fam > 0 || (List.length events) > 0 then true else false
        | _ ->
            (* Renvoie vrai que si il y a des informations supplémentaires *)
            (* par rapport aux évènements principaux, i.e. témoins (mais   *)
            (* on ne prend pas en compte les notes).                       *)
            let rec loop events nb_birth nb_bapt nb_deat nb_buri nb_marr =
              match events with
                [] -> false
              | (name, _, p, n, s, wl, _) :: events ->
                  let (p, n, s) = sou base p, sou base n, sou base s in
                  match name with
                    Pevent pname ->
                      begin match pname with
                        Epers_Birth | Epers_Baptism | Epers_Death |
                        Epers_Burial | Epers_Cremation ->
                          if Array.length wl > 0 then true
                          else
                            let (nb_birth, nb_bapt, nb_deat, nb_buri) =
                              match pname with
                                Epers_Birth ->
                                  succ nb_birth, nb_bapt, nb_deat, nb_buri
                              | Epers_Baptism ->
                                  nb_birth, succ nb_bapt, nb_deat, nb_buri
                              | Epers_Death ->
                                  nb_birth, nb_bapt, succ nb_deat, nb_buri
                              | Epers_Burial | Epers_Cremation ->
                                  nb_birth, nb_bapt, nb_deat, succ nb_buri
                              | _ -> nb_birth, nb_bapt, nb_deat, nb_buri
                            in
                            if List.exists (fun i -> i > 1)
                                 [nb_birth; nb_bapt; nb_deat; nb_buri]
                            then
                              true
                            else
                              loop events nb_birth nb_bapt nb_deat nb_buri
                                nb_marr
                      | _ -> true
                      end
                  | Fevent fname ->
                      match fname with
                        Efam_Engage | Efam_Marriage | Efam_NoMention |
                        Efam_NoMarriage ->
                          let nb_marr = succ nb_marr in
                          if nb_marr > nb_fam then true
                          else
                            loop events nb_birth nb_bapt nb_deat nb_buri
                              nb_marr
                      | Efam_Divorce | Efam_Separated ->
                          if p <> "" || n <> "" || s <> "" ||
                             Array.length wl > 0
                          then
                            true
                          else
                            loop events nb_birth nb_bapt nb_deat nb_buri
                              nb_marr
                      | _ -> true
            in
            loop events 0 0 0 0 0
      else false
  | "has_families" ->
      Array.length (get_family p) > 0
      || !GWPARAM_ITL.has_family_correspondance conf.command (get_iper p)
  | "has_first_names_aliases" ->
      if not p_auth && is_hide_names conf p then false
      else get_first_names_aliases p <> []
  | "has_history" -> has_history conf base p p_auth
  | "has_image" -> Util.has_image conf base p
  | "has_nephews_or_nieces" -> has_nephews_or_nieces conf base p
  | "has_nobility_titles" -> p_auth && nobtit conf base p <> []
  | "has_notes" | "has_pnotes" ->
      p_auth && not conf.no_note && sou base (get_notes p) <> ""
  | "has_occupation" -> p_auth && sou base (get_occupation p) <> ""
  | "has_parents" ->
      get_parents p <> None
      || let conf =
           match get_env "baseprefix" env with
           | Vstring baseprefix -> {conf with command = baseprefix}
           | _ -> conf
      in !GWPARAM_ITL.has_parents_link conf.command (get_iper p)
  | "has_possible_duplications" -> has_possible_duplications conf base p
  | "has_psources" ->
      if is_hide_names conf p && not p_auth then false
      else sou base (get_psources p) <> ""
  | "has_public_name" ->
      if not p_auth && is_hide_names conf p then false
      else sou base (get_public_name p) <> ""
  | "has_qualifiers" ->
      if not p_auth && is_hide_names conf p then false
      else get_qualifiers p <> []
  | "has_relations" ->
      if p_auth && conf.use_restrict then
        let related =
          List.fold_left
            (fun l ip ->
               let rp = pget conf base ip in
               if is_hidden rp then l else ip :: l)
            [] (get_related p)
        in
        get_rparents p <> [] || related <> []
      else p_auth && (get_rparents p <> [] || get_related p <> [])
  | "has_siblings" ->
      begin match get_parents p with
        Some ifam -> Array.length (get_children (foi base ifam)) > 1
      | None ->
          let conf =
            match get_env "baseprefix" env with
            | Vstring baseprefix -> {conf with command = baseprefix}
            | _ -> conf
          in !GWPARAM_ITL.has_siblings conf.command (get_iper p)
      end
  | "has_sources" ->
      p_auth &&
      (sou base (get_psources p) <> "" || sou base (get_birth_src p) <> "" ||
       sou base (get_baptism_src p) <> "" ||
       sou base (get_death_src p) <> "" ||
       sou base (get_burial_src p) <> "" ||
       Array.exists
         (fun ifam ->
            let fam = foi base ifam in
            let isp = Gutil.spouse (get_iper p) fam in
            let sp = poi base isp in
            (* On sait que p_auth vaut vrai. *)
            let m_auth = authorized_age conf base sp in
            m_auth &&
            (sou base (get_marriage_src fam) <> "" ||
             sou base (get_fsources fam) <> ""))
         (get_family p))
  | "has_surnames_aliases" ->
      if not p_auth && is_hide_names conf p then false
      else get_surnames_aliases p <> []
  | "is_buried" ->
      begin match get_burial p with
        Buried _ -> p_auth
      | _ -> false
      end
  | "is_cremated" ->
      begin match get_burial p with
        Cremated _ -> p_auth
      | _ -> false
      end
  | "is_dead" ->
      begin match get_death p with
        Death (_, _) | DeadYoung | DeadDontKnowWhen -> p_auth
      | _ -> false
      end
  | "is_certainly_dead" ->
      begin match get_death p with
        OfCourseDead -> p_auth
      | _ -> false
      end
  | "is_descendant" ->
      begin match get_env "desc_mark" env with
        Vdmark r -> (Gwdb.Marker.get !r (get_iper p))
      | _ -> raise Not_found
      end
  | "is_female" -> get_sex p = Female
  | "is_invisible" ->
      let conf = {conf with wizard = false; friend = false} in
      not (authorized_age conf base p)
  | "is_male" -> get_sex p = Male
  | "is_private" -> get_access p = Private
  | "is_public" -> get_access p = Public
  | "is_restricted" -> is_hidden p
  | _ -> raise Not_found
and eval_str_person_field conf base env (p, p_auth as ep) =
  function
  | "access" -> acces conf base p |> safe_val
  | "age" ->
      begin match p_auth, Adef.od_of_cdate (get_birth p), get_death p with
        true, Some (Dgreg (d, _)), NotDead ->
          Date.time_elapsed d conf.today
          |> DateDisplay.string_of_age conf
          |> safe_val
      | _ -> null_val
      end
  | "alias" ->
      begin match get_aliases p with
        nn :: _ ->
          if not p_auth && is_hide_names conf p
          then null_val
          else sou base nn |> Util.escape_html |> safe_val
      | _ -> null_val
      end
  | "approx_birth_place" ->
    if p_auth then Util.get_approx_birth_date_place conf base p |> snd |> safe_val
    else null_val
  | "approx_death_place" ->
      if p_auth then Util.get_approx_death_date_place conf base p |> snd |> safe_val
      else null_val
  | "auto_image_file_name" ->
      if p_auth then match auto_image_file conf base p with
        | Some x -> str_val x
        | None -> null_val
      else null_val
  | "bname_prefix" -> Util.commd conf |> safe_val
  | "birth_place" ->
      if p_auth
      then get_birth_place p |> sou base |> Util.string_of_place conf |> safe_val
      else null_val
  | "birth_note" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_birth_note p
      |> sou base
      |> get_note_source conf base env p_auth conf.no_note
      |> safe_val
  | "birth_source" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_birth_src p
      |> sou base
      |> get_note_source conf base env p_auth false
      |> safe_val
  | "baptism_place" ->
      if p_auth then
        get_baptism_place p
        |> sou base
        |> Util.string_of_place conf
        |> safe_val
      else null_val
  | "baptism_note" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_baptism_note p
      |> sou base
      |> get_note_source conf base env p_auth conf.no_note
      |> safe_val
  | "baptism_source" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_baptism_src p
      |> sou base
      |> get_note_source conf base env p_auth false
      |> safe_val
  | "burial_place" ->
      if p_auth
      then
        get_burial_place p
        |> sou base
        |> Util.string_of_place conf
        |> safe_val
      else null_val
  | "burial_note" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_burial_note p
      |> sou base
      |> get_note_source conf base env p_auth conf.no_note
      |> safe_val
  | "burial_source" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_burial_src p
      |> sou base
      |> get_note_source conf base env p_auth false
      |> safe_val
  | "child_name" ->
      let force_surname =
        match get_parents p with
          None -> false
        | Some ifam ->
          foi base ifam
          |> get_father
          |> pget conf base
          |> p_surname base
          |> (<>) (p_surname base p)
      in
      if not p_auth && is_hide_names conf p then str_val "x x"
      else if force_surname then gen_person_text conf base p |> safe_val
      else gen_person_text ~sn:false ~chk:false conf base p |> safe_val
  | "consanguinity" ->
      if p_auth then
        string_of_decimal_num conf (round_2_dec (Adef.float_of_fix (get_consang p) *. 100.0))
        ^ " %"
        |> str_val
      else null_val
  | "cremation_place" ->
      if p_auth then
        get_burial_place p
        |> sou base
        |> Util.string_of_place conf
        |> safe_val
      else null_val
  | "dates" ->
    if p_auth then DateDisplay.short_dates_text conf base p |> safe_val
    else null_val
  | "death_age" ->
      if p_auth then
        match Gutil.get_birth_death_date p with
          Some (Dgreg (({prec = Sure | About | Maybe} as d1), _)),
          Some (Dgreg (({prec = Sure | About | Maybe} as d2), _)), approx
          when d1 <> d2 ->
            let a = Date.time_elapsed d1 d2 in
            let s =
              if not approx && d1.prec = Sure && d2.prec = Sure then ""
              else transl_decline conf "possibly (date)" "" ^ " "
            in
            s ^<^ DateDisplay.string_of_age conf a
            |> safe_val
        | _ -> null_val
      else null_val
  | "death_place" ->
      if p_auth then
        get_death_place p
        |> sou base
        |> Util.string_of_place conf
        |> safe_val
      else null_val
  | "death_note" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_death_note p
      |> sou base
      |> get_note_source conf base env p_auth conf.no_note
      |> safe_val
  | "death_source" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_death_src p
      |> sou base
      |> get_note_source conf base env p_auth false
      |> safe_val
  | "died" -> string_of_died conf p p_auth |> safe_val
  | "father_age_at_birth" -> string_of_parent_age conf base ep get_father |> safe_val
  | "first_name" ->
      if not p_auth && is_hide_names conf p
      then str_val "x"
      else p_first_name base p |> Util.escape_html |> safe_val
  | "first_name_key" ->
      if is_hide_names conf p && not p_auth
      then null_val
      else p_first_name base p |> Name.lower |> Mutil.encode |> safe_val
  | "first_name_key_val" ->
      if is_hide_names conf p && not p_auth then null_val
      else p_first_name base p |> Name.lower |> str_val
  | "first_name_key_strip" ->
      if is_hide_names conf p && not p_auth then null_val
      else Name.strip_c (p_first_name base p) '"' |> str_val
  | "history_file" ->
      if not p_auth then null_val
      else
        let fn = sou base (get_first_name p) in
        let sn = sou base (get_surname p) in
        let occ = get_occ p in
        HistoryDiff.history_file fn sn occ
        |> str_val
  | "image" -> if not p_auth then null_val else get_image p |> sou base |> str_val
  | "image_html_url" -> string_of_image_url conf base ep true |> safe_val
  | "image_size" -> string_of_image_size conf base ep |> str_val
  | "image_medium_size" -> string_of_image_medium_size conf base ep |> str_val
  | "image_small_size" -> string_of_image_small_size conf base ep |> str_val
  | "image_url" -> string_of_image_url conf base ep false |> safe_val
  | "index" ->
      begin match get_env "p_link" env with
        Vbool _ -> null_val
      | _ -> get_iper p |> string_of_iper |> Mutil.encode |> safe_val
      end
  | "mark_descendants" ->
      begin match get_env "desc_mark" env with
        Vdmark r ->
          let tab = Gwdb.iper_marker (Gwdb.ipers base) false in
          let rec mark_descendants len p =
            let i = (get_iper p) in
            if Gwdb.Marker.get tab i then ()
            else
              begin
                Gwdb.Marker.set tab i true;
                let u = p in
                for i = 0 to Array.length (get_family u) - 1 do
                  let des = foi base (get_family u).(i) in
                  for i = 0 to Array.length (get_children des) - 1 do
                    mark_descendants (len + 1)
                      (pget conf base (get_children des).(i))
                  done
                done
              end
          in
          mark_descendants 0 p; r := tab; null_val
      | _ -> raise Not_found
      end
  | "marriage_age" ->
      begin match get_env "fam" env with
        Vfam (_, fam, _, m_auth) ->
          if m_auth then
            match
              Adef.od_of_cdate (get_birth p),
              Adef.od_of_cdate (get_marriage fam)
            with
              Some (Dgreg (({prec = Sure | About | Maybe} as d1), _)),
              Some (Dgreg (({prec = Sure | About | Maybe} as d2), _)) ->
                Date.time_elapsed d1 d2
                |> DateDisplay.string_of_age conf
                |> safe_val
            | _ -> null_val
          else null_val
      | _ -> raise Not_found
      end
  | "mother_age_at_birth" -> string_of_parent_age conf base ep get_mother |> safe_val
  | "misc_names" ->
      if p_auth then
        let list =
          Util.nobtit conf base
          |> Gwdb.person_misc_names base p
          |> List.map Util.escape_html
        in
        let list =
          let first_name = p_first_name base p in
          let surname = p_surname base p in
          if first_name <> "?" && surname <> "?"
          then (first_name ^ " " ^ surname |> Name.lower |> Util.escape_html) :: list
          else list
        in
        if list <> [] then
          "<ul>"
          ^<^
          List.fold_left
            (fun s n -> s ^^^ "<li>" ^<^ n ^>^ "</li>")
            (Adef.safe "") (list : Adef.escaped_string list :> Adef.safe_string list)
          ^>^
          "</ul>"
          |> safe_val
        else null_val
      else null_val
  | "nb_children_total" ->
    Array.fold_left
      (fun n ifam -> n + Array.length (get_children (foi base ifam))) 0
      (get_family p)
    |> string_of_int
    |> str_val
  | "nb_children" ->
      begin match get_env "fam" env with
        Vfam (_, fam, _, _) ->
        get_children fam
        |> Array.length
        |> string_of_int
        |> str_val
      | _ ->
          match get_env "fam_link" env with
            Vfam (ifam, _, _, _) ->
            let baseprefix =
              match get_env "baseprefix" env with
              | Vstring baseprefix -> baseprefix
              | _ -> conf.command
            in string_of_int (!GWPARAM_ITL.nb_children baseprefix ifam)
               |> str_val
          | _ ->
            Array.fold_left
              (fun n ifam -> n + Array.length (get_children (foi base ifam)))
              0 (get_family p)
            |> string_of_int
            |> str_val
      end
  | "nb_families" ->
      begin match get_env "p_link" env with
        | Vbool _ ->
          get_iper p
          |> !GWPARAM_ITL.nb_families conf.command
          |> string_of_int
          |> str_val
        | _ ->
          get_family p
          |> Array.length
          |> string_of_int
          |> str_val
      end
  | "notes" | "pnotes" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_notes p
      |> sou base
      |> get_note_source conf base env p_auth conf.no_note
      |> safe_val
  | "occ" ->
      if is_hide_names conf p && not p_auth then null_val
      else get_occ p |> string_of_int |> str_val
  | "occupation" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_occupation p
      |> sou base
      |> get_note_source conf base env p_auth false
      |> safe_val
  | "on_baptism_date" ->
    date_aux conf p_auth (get_baptism p)
  | "slash_baptism_date" ->
    if p_auth
    then match Adef.od_of_cdate (get_baptism p) with
      | Some d -> DateDisplay.string_slash_of_date conf d |> safe_val
      | None -> null_val
    else null_val
  | "on_birth_date" ->
    date_aux conf p_auth (get_birth p)
  | "slash_birth_date" ->
      if p_auth then match Adef.od_of_cdate (get_birth p) with
        | Some d -> DateDisplay.string_slash_of_date conf d |> safe_val
        | _ -> null_val
      else null_val
  | "slash_approx_birth_date" ->
      if p_auth then match fst (Util.get_approx_birth_date_place conf base p) with
        | Some d -> DateDisplay.string_slash_of_date conf d |> safe_val
        | None -> null_val
      else null_val
  | "on_burial_date" ->
    begin match get_burial p with
      | Buried cod -> date_aux conf p_auth cod
      | _ -> raise Not_found
    end
  | "psources" ->
      let env = ['i', (fun () -> Util.default_image_name base p)] in
      get_psources p
      |> sou base
      |> get_note_source conf base env p_auth false
      |> safe_val
  | "slash_burial_date" ->
    if p_auth then match get_burial p with
      | Buried cod ->
        begin match Adef.od_of_cdate cod with
          | Some d -> DateDisplay.string_slash_of_date conf d |> safe_val
          | _ -> null_val
        end
      | _ -> raise Not_found
    else null_val
  | "on_cremation_date" ->
    begin match get_burial p with
      | Cremated cod -> date_aux conf p_auth cod
      | _ -> raise Not_found
    end
  | "slash_cremation_date" ->
      begin match get_burial p with
        Cremated cod ->
          begin match p_auth, Adef.od_of_cdate cod with
            true, Some d -> DateDisplay.string_slash_of_date conf d |> safe_val
          | _ -> null_val
          end
      | _ -> raise Not_found
      end
  | "on_death_date" ->
    begin match get_death p with
      | Death (_, d) -> date_aux conf p_auth d
      | _ -> raise Not_found
    end
  | "slash_death_date" ->
    begin match p_auth, get_death p with
      | true, Death (_, d) ->
        Adef.date_of_cdate d
        |> DateDisplay.string_slash_of_date conf
        |> safe_val
      | _ -> null_val
    end
  | "slash_approx_death_date" ->
    begin match p_auth, fst (Util.get_approx_death_date_place conf base p) with
      | true, Some d -> DateDisplay.string_slash_of_date conf d |> safe_val
      | _ -> null_val
    end
  | "prev_fam_father" ->
    begin match get_env "prev_fam" env with
      | Vfam (_, _, (ifath, _, _), _) -> string_of_iper ifath |> Mutil.encode |> safe_val
      | _ -> raise Not_found
    end
  | "prev_fam_index" ->
    begin match get_env "prev_fam" env with
      | Vfam (ifam, _, _, _) -> string_of_ifam ifam |> Mutil.encode |> safe_val
      | _ -> raise Not_found
    end
  | "prev_fam_mother" ->
    begin match get_env "prev_fam" env with
      | Vfam (_, _, (_, imoth, _), _) -> string_of_iper imoth |> Mutil.encode |> safe_val
      | _ -> raise Not_found
    end
  | "public_name" ->
    if not p_auth && is_hide_names conf p then null_val
    else get_public_name p |> sou base |> Util.escape_html |> safe_val
  | "qualifier" ->
    begin match get_qualifiers p with
      | nn :: _ when p_auth || not (is_hide_names conf p) ->
        sou base nn
        |> Util.escape_html
        |> safe_val
      | _ -> null_val
    end
  | "sex" ->
    (* Pour éviter les traductions bizarre, on ne teste pas p_auth. *)
    get_sex p |> index_of_sex |> string_of_int |> str_val
  | "sosa_in_list" ->
    begin match get_env "all_gp" env with
      | Vallgp all_gp ->
        begin match get_link all_gp (get_iper p) with
          | Some (GP_person (s, _, _)) -> str_val (Sosa.to_string s)
          | _ -> null_val
        end
      | _ -> raise Not_found
    end
  | "sosa_link" ->
    begin match get_env "sosa" env with
      | Vsosa x ->
        begin match get_sosa conf base env x p with
          | Some (n, q) ->
            Printf.sprintf "m=RL&i1=%s&i2=%s&b1=1&b2=%s"
              (string_of_iper (get_iper p))
              (string_of_iper (get_iper q))
              (Sosa.to_string n)
            |> str_val
          | None -> null_val
        end
      | _ -> raise Not_found
    end
  | "source" ->
    begin match get_env "src" env with
      | Vstring s -> safe_val (Notes.source_note conf base p s)
      | _ -> raise Not_found
    end
  | "surname" ->
    if not p_auth && is_hide_names conf p
    then str_val "x"
    else
      p_surname base p
      |> Util.escape_html
      |> safe_val
  | "surname_begin" ->
    if not p_auth && is_hide_names conf p
    then null_val
    else
      p_surname base p
      |> surname_particle base
      |> Util.escape_html
      |> safe_val
  | "surname_end" ->
    if not p_auth && is_hide_names conf p
    then str_val "x"
    else
      p_surname base p
      |> surname_without_particle base
      |> Util.escape_html
      |> safe_val
  | "surname_key" ->
    if is_hide_names conf p && not p_auth then null_val
    else
      p_surname base p
      |> Name.lower
      |> Mutil.encode
      |> safe_val
  | "surname_key_val" ->
    if is_hide_names conf p && not p_auth then null_val
    else
      p_surname base p
      |> Name.lower
      |> str_val
  | "surname_key_strip" ->
    if is_hide_names conf p && not p_auth then null_val
    else
      Name.strip_c (p_surname base p) '"'
      |> str_val
  | "title" ->
    person_title conf base p |> safe_val
  | _ -> raise Not_found
and eval_witness_relation_var conf base env (_, _, (ip1, ip2, _), m_auth as fcd) loc =
    function
    | [] ->
      if not m_auth then null_val
      else
        Printf.sprintf (ftransl conf "witness at marriage of %s and %s")
          (pget conf base ip1 |> referenced_person_title_text conf base :> string)
          (pget conf base ip2 |> referenced_person_title_text conf base :> string)
        |> str_val
    | sl -> eval_family_field_var conf base env fcd loc sl
and eval_family_field_var conf base env (_, fam, (ifath, imoth, _), m_auth as fcd) loc =
    function
    "father" :: sl ->
      begin match get_env "f_link" env with
        Vbool _ -> raise Not_found
      | _ ->
          let ep = make_ep conf base ifath in
          eval_person_field_var conf base env ep loc sl
      end
  | "marriage_date" :: sl ->
      begin match Adef.od_of_cdate (get_marriage fam) with
        Some d when m_auth -> eval_date_field_var conf d sl
      | _ -> null_val
      end
  | "mother" :: sl ->
      begin match get_env "f_link" env with
        Vbool _ -> raise Not_found
      | _ ->
          let ep = make_ep conf base imoth in
          eval_person_field_var conf base env ep loc sl
      end
  | [s] -> str_val (eval_str_family_field env fcd s)
  | _ -> raise Not_found
and eval_str_family_field env (ifam, _, _, _) =
  function
    "desc_level" ->
      begin match get_env "desc_level_table" env with
        Vdesclevtab levt ->
          let (_, flevt) = Lazy.force levt in
          string_of_int (Gwdb.Marker.get flevt ifam)
      | _ -> raise Not_found
      end
  | "index" -> string_of_ifam ifam
  | "set_infinite_desc_level" ->
      begin match get_env "desc_level_table" env with
        Vdesclevtab levt ->
          let (_, flevt) = Lazy.force levt in
          Gwdb.Marker.set flevt ifam infinite; ""
      | _ -> raise Not_found
      end
  | _ -> raise Not_found
and simple_person_text conf base p p_auth : Adef.safe_string =
  if p_auth then
    match main_title conf base p with
      Some t -> titled_person_text conf base p t
    | None -> gen_person_text conf base p
  else if is_hide_names conf p then Adef.safe "x x"
  else gen_person_text conf base p
and string_of_died conf p p_auth =
  if p_auth then
    let is = index_of_sex (get_sex p) in
    match get_death p with
      Death (dr, _) ->
        begin match dr with
          Unspecified -> transl_nth conf "died" is |> Adef.safe
        | Murdered -> transl_nth conf "murdered" is |> Adef.safe
        | Killed -> transl_nth conf "killed (in action)" is |> Adef.safe
        | Executed -> transl_nth conf "executed (legally killed)" is |> Adef.safe
        | Disappeared -> transl_nth conf "disappeared" is |> Adef.safe
        end
    | DeadYoung -> transl_nth conf "died young" is |> Adef.safe
    | DeadDontKnowWhen -> transl_nth conf "died" is |> Adef.safe
    | _ -> Adef.safe ""
  else Adef.safe ""
and string_of_image_url conf base (p, p_auth) html : Adef.escaped_string =
  if p_auth then
    match image_and_size conf base p (limited_image_size max_im_wid max_im_wid) with
    | Some (true, fname, _) ->
      let s = Unix.stat fname in
      let b = acces conf base p in
      let k = default_image_name base p in
      Format.sprintf "%sm=IM%s&d=%d&%s&k=/%s"
        (commd conf :> string)
        (if html then "H" else "")
        (int_of_float (mod_float s.Unix.st_mtime (float_of_int max_int)))
        (b :> string)
        k
      |> Adef.escaped
    | Some (false, link, _) -> Adef.escaped link (* FIXME *)
    | None -> Adef.escaped ""
  else Adef.escaped ""
and string_of_parent_age conf base (p, p_auth) parent : Adef.safe_string =
  match get_parents p with
    Some ifam ->
      let cpl = foi base ifam in
      let pp = pget conf base (parent cpl) in
      if p_auth && authorized_age conf base pp then
        match Adef.od_of_cdate (get_birth pp), Adef.od_of_cdate (get_birth p) with
        | Some (Dgreg (d1, _)), Some (Dgreg (d2, _)) ->
          Date.time_elapsed d1 d2 |> DateDisplay.string_of_age conf
        | _ -> Adef.safe ""
      else Adef.safe ""
  | None -> raise Not_found
and string_of_int_env var env =
  match get_env var env with
  | Vint x -> string_of_int x |> str_val
  | _ -> raise Not_found

let eval_transl conf base env upp s c =
  match c with
    "n" | "s" | "w" | "f" | "c" ->
      let n =
        match c with
          "n" ->
            (* replaced by %apply;nth([...],sex) *)
            begin match get_env "p" env with
              Vind p -> 1 - index_of_sex (get_sex p)
            | _ -> 2
            end
        | "s" ->
            begin match get_env "child" env with
              Vind p -> index_of_sex (get_sex p)
            | _ ->
                match get_env "p" env with
                  Vind p -> index_of_sex (get_sex p)
                | _ -> 2
            end
        | "w" ->
            begin match get_env "fam" env with
              Vfam (_, fam, _, _) ->
                if Array.length (get_witnesses fam) <= 1 then 0 else 1
            | _ -> 0
            end
        | "f" ->
            begin match get_env "p" env with
              Vind p -> if Array.length (get_family p) <= 1 then 0 else 1
            | _ -> 0
            end
        | "c" ->
            begin match get_env "fam" env with
              Vfam (_, fam, _, _) ->
                if Array.length (get_children fam) <= 1 then 0 else 1
            | _ ->
                match get_env "p" env with
                  Vind p ->
                    let n =
                      Array.fold_left
                        (fun n ifam ->
                           n + Array.length (get_children (foi base ifam)))
                        0 (get_family p)
                    in
                    if n <= 1 then 0 else 1
                | _ -> 0
            end
        | _ -> assert false
      in
      let r = Util.translate_eval (Util.transl_nth conf s n) in
      if upp then Utf8.capitalize_fst r else r
  | _ -> Templ.eval_transl conf upp s c

let print_foreach conf base print_ast eval_expr =
  let eval_int_expr env ep e =
    let s = eval_expr env ep e in
    try int_of_string s with Failure _ -> raise Not_found
  in
  let rec print_foreach env ini_ep loc s sl ell al =
    let rec loop env (a, _ as ep) efam =
      function
        [s] -> print_simple_foreach env ell al ini_ep ep efam loc s
      | "ancestor" :: sl ->
          let ip_ifamo =
            match get_env "ancestor" env with
              Vanc (GP_person (_, ip, ifamo)) -> Some (ip, ifamo)
            | Vanc (GP_same (_, _, ip)) -> Some (ip, None)
            | _ -> None
          in
          begin match ip_ifamo with
            Some (ip, ifamo) ->
              let ep = make_ep conf base ip in
              let efam =
                match ifamo with
                  Some ifam ->
                    let (f, c, a) = make_efam conf base ip ifam in
                    Vfam (ifam, f, c, a)
                | None -> efam
              in
              loop env ep efam sl
          | _ -> raise Not_found
          end
      | "child" :: sl ->
          begin match get_env "child" env with
            Vind p ->
              let auth = authorized_age conf base p in
              let ep = p, auth in loop env ep efam sl
          | _ ->
              match get_env "child_link" env with
                Vind p ->
                  let env = ("p_link", Vbool true) :: env in
                  let env = ("f_link", Vbool true) :: env in
                  let auth = authorized_age conf base p in
                  let ep = p, auth in loop env ep efam sl
              | _ -> raise Not_found
          end
      | "father" :: sl ->
        begin match get_parents a with
          | Some ifam ->
            let cpl = foi base ifam in
            let (_, p_auth as ep) = make_ep conf base (get_father cpl) in
            let ifath = get_father cpl in
            let cpl = ifath, get_mother cpl, ifath in
            let m_auth =
              p_auth && authorized_age conf base (pget conf base ifath)
            in
            let efam = Vfam (ifam, foi base ifam, cpl, m_auth) in
            loop env ep efam sl
          | None ->
            let conf =
              match get_env "baseprefix" env with
                Vstring baseprefix -> {conf with command = baseprefix}
              | _ -> conf
            in
            match !GWPARAM_ITL.get_father' conf base (get_iper a) with
            | Some (baseprefix, ep, ifam, fam, cpl) ->
              let efam = Vfam (ifam, fam, cpl, true) in
              let env = ("p_link", Vbool true) :: env in
              let env = ("f_link", Vbool true) :: env in
              let env = ("baseprefix", Vstring baseprefix) :: env in
              loop env ep efam sl
            | None ->
              warning_use_has_parents_before_parent loc "father" ()
        end
      | "mother" :: sl ->
          begin match get_parents a with
            Some ifam ->
              let cpl = foi base ifam in
              let (_, p_auth as ep) = make_ep conf base (get_mother cpl) in
              let ifath = get_father cpl in
              let cpl = ifath, get_mother cpl, ifath in
              let m_auth =
                p_auth && authorized_age conf base (pget conf base ifath)
              in
              let efam = Vfam (ifam, foi base ifam, cpl, m_auth) in
              loop env ep efam sl
          | None ->
            match !GWPARAM_ITL.get_mother' conf base (get_iper a) with
            | Some (baseprefix, ep, ifam, fam, cpl) ->
              let efam = Vfam (ifam, fam, cpl, true) in
              let env = ("p_link", Vbool true) :: env in
              let env = ("f_link", Vbool true) :: env in
              let env = ("baseprefix", Vstring baseprefix) :: env in
              loop env ep efam sl
            | None -> warning_use_has_parents_before_parent loc "mother" ()
          end
      | "self" :: sl -> loop env ep efam sl
      | "spouse" :: sl ->
          begin match efam with
            Vfam (_, _, (_, _, ip), _) ->
              let ep = make_ep conf base ip in loop env ep efam sl
          | _ ->
              match get_env "fam_link" env with
                Vfam (_, _, (_, _, ip), _) ->
                  let baseprefix =
                    match get_env "baseprefix" env with
                      Vstring baseprefix -> baseprefix
                    | _ -> conf.command
                  in
                  begin match !GWPARAM_ITL.get_person conf base baseprefix ip with
                    Some (ep, baseprefix) ->
                      let env = ("p_link", Vbool true) :: env in
                      let env = ("baseprefix", Vstring baseprefix) :: env in
                      loop env ep efam sl
                  | None -> raise Not_found
                  end
              | _ -> raise Not_found
          end
      | _ -> raise Not_found
    in
    let efam =
      match get_env "is_link" env with
        Vbool _ -> get_env "fam_link" env
      | _ -> get_env "fam" env
    in
    loop env ini_ep efam (s :: sl)
  and print_simple_foreach env el al ini_ep ep efam loc =
    function
      "alias" -> print_foreach_alias env al ep
    | "ancestor" -> print_foreach_ancestor env al ep
    | "ancestor_level" -> print_foreach_ancestor_level env el al ep
    | "ancestor_level2" -> print_foreach_ancestor_level2 env al ep
    | "ancestor_surname" -> print_foreach_anc_surn env el al loc ep
    | "ancestor_tree_line" -> print_foreach_ancestor_tree env el al ep
    | "baptism_witness" -> print_foreach_baptism_witness env al ep
    | "birth_witness" -> print_foreach_birth_witness env al ep
    | "burial_witness" -> print_foreach_burial_witness env al ep
    | "cell" -> print_foreach_cell env al ep
    | "child" -> print_foreach_child env al ep efam
    | "cousin_level" -> print_foreach_level "max_cous_level" env al ep
    | "cremation_witness" -> print_foreach_cremation_witness env al ep
    | "death_witness" -> print_foreach_death_witness env al ep
    | "descendant_level" -> print_foreach_descendant_level env al ep
    | "event" -> print_foreach_event env al ep
    | "event_witness" -> print_foreach_event_witness env al ep
    | "event_witness_relation" ->
        print_foreach_event_witness_relation env al ep
    | "family" -> print_foreach_family env al ini_ep ep
    | "first_name_alias" -> print_foreach_first_name_alias env al ep
    | "nobility_title" -> print_foreach_nobility_title env al ep
    | "parent" -> print_foreach_parent env al ep
    | "qualifier" -> print_foreach_qualifier env al ep
    | "related" -> print_foreach_related env al ep
    | "relation" -> print_foreach_relation env al ep
    | "sorted_list_item" -> print_foreach_sorted_list_item env al ep
    | "sorted_listb_item" -> print_foreach_sorted_listb_item env al ep
    | "sorted_listc_item" -> print_foreach_sorted_listc_item env al ep
    | "source" -> print_foreach_source env al ep
    | "surname_alias" -> print_foreach_surname_alias env al ep
    | "witness" -> print_foreach_witness env al ep efam
    | "witness_relation" -> print_foreach_witness_relation env al ep
    | _ -> raise Not_found
  and print_foreach_alias env al (p, p_auth as ep) =
    if not p_auth && is_hide_names conf p then ()
    else
      Mutil.list_iter_first
        (fun first a ->
           let env = ("alias", Vstring (sou base a)) :: env in
           let env = ("first", Vbool first) :: env in
           List.iter (print_ast env ep) al)
        (get_aliases p)
  and print_foreach_ancestor env al ep =
    match get_env "gpl" env with
      Vgpl gpl ->
        let rec loop first gpl =
          match gpl with
            [] -> ()
          | gp :: gl ->
              begin match gp with
                GP_missing (_, _) -> ()
              | _ ->
                  let env =
                    ("ancestor", Vanc gp) :: ("first", Vbool first) ::
                    ("last", Vbool (gl = [])) :: env
                  in
                  List.iter (print_ast env ep) al
              end;
              loop false gl
        in
        loop true gpl
    | _ -> ()
  and print_foreach_ancestor_level env el al (p, _ as ep) =
    let max_level =
      match el with
        [[e]] -> eval_int_expr env ep e
      | [] ->
          begin match get_env "max_anc_level" env with
            Vint n -> n
          | _ -> 0
          end
      | _ -> raise Not_found
    in
    let mark = Gwdb.iper_marker (Gwdb.ipers base) Sosa.zero in
    let rec loop gpl i n =
      if i > max_level then ()
      else
        let n =
          List.fold_left
            (fun n gp ->
               match gp with
                 GP_person (_, _, _) -> n + 1
               | _ -> n)
            n gpl
        in
        let env =
          ("gpl", Vgpl gpl) :: ("level", Vint i) :: ("n", Vint n) :: env
        in
        List.iter (print_ast env ep) al;
        let gpl = next_generation conf base mark gpl in loop gpl (succ i) n
    in
    loop [GP_person (Sosa.one, get_iper p, None)] 1 0
  and print_foreach_ancestor_level2 env al (p, _ as ep) =
    let max_lev = "max_anc_level" in
    let max_level =
      match get_env max_lev env with
        Vint n -> n
      | _ -> 0
    in
    let mark = Gwdb.iper_marker (Gwdb.ipers base) Sosa.zero in
    let rec loop gpl i =
      if i > max_level then ()
      else
        let env = ("gpl", Vgpl gpl) :: ("level", Vint i) :: env in
        List.iter (print_ast env ep) al;
        Gwdb.Collection.iter (fun i -> Gwdb.Marker.set mark i Sosa.zero) (Gwdb.ipers base) ;
        let gpl = next_generation2 conf base mark gpl in loop gpl (succ i)
    in
    loop [GP_person (Sosa.one, get_iper p, None)] 1
  and print_foreach_anc_surn env el al loc (p, _ as ep) =
    let max_level =
      match el with
        [[e]] -> eval_int_expr env ep e
      | [] ->
          begin match get_env "max_anc_level" env with
            Vint n -> n
          | _ -> 0
          end
      | _ -> raise Not_found
    in
    (* En fonction du type de sortie demandé, on construit *)
    (* soit la liste des branches soit la liste éclair.    *)
    match p_getenv conf.env "t" with
      Some "E" ->
        let list = build_list_eclair conf base max_level p in
        List.iter
          (fun (a, b, c, d, e, f) ->
             let b = (b : Adef.escaped_string :> Adef.safe_string) in
             let env =
               ("ancestor", Vanc_surn (Eclair (a, b, c, d, e, f, loc))) :: env
             in
             List.iter (print_ast env ep) al)
          list
    | Some "F" ->
        let list = build_surnames_list conf base max_level p in
        List.iter
          (fun (a, (((b, c, d), e), f)) ->
             let env =
               ("ancestor", Vanc_surn (Branch (a, b, c, d, e, f, loc))) :: env
             in
             List.iter (print_ast env ep) al)
          list
    | _ -> ()
  and print_foreach_ancestor_tree env el al (p, _ as ep) =
    let (p, max_level) =
      match el with
        [[e1]; [e2]] ->
          let ip = iper_of_string @@ eval_expr env ep e1 in
          let max_level = eval_int_expr env ep e2 in
          pget conf base ip, max_level
      | [[e]] -> p, eval_int_expr env ep e
      | [] ->
          begin match get_env "max_anc_level" env with
            Vint n -> p, n
          | _ -> p, 0
          end
      | _ -> raise Not_found
    in
    let gen = tree_generation_list conf base max_level p in
    let rec loop first =
      function
        g :: gl ->
          let env =
            ("celll", Vcelll g) :: ("first", Vbool first) ::
            ("last", Vbool (gl = [])) :: env
          in
          List.iter (print_ast env ep) al; loop false gl
      | [] -> ()
    in
    loop true gen
  and print_foreach_baptism_witness env al (p, _ as ep) =
    let rec loop pevents =
      match pevents with
        [] -> ()
      | (name, _, _, _, _, wl, _) :: events ->
          if name = Pevent Epers_Baptism then
            Array.iteri
              begin fun i (ip, _) ->
                let p = pget conf base ip in
                let env =
                  ("baptism_witness", Vind p)
                  :: ("first", Vbool (i = 0))
                  :: env
                in
                List.iter (print_ast env ep) al
              end
              wl
          else loop events
    in
    loop (events_list conf base p)
  and print_foreach_birth_witness env al (p, _ as ep) =
    let rec loop pevents =
      match pevents with
        [] -> ()
      | (name, _, _, _, _, wl, _) :: events ->
          if name = Pevent Epers_Birth then
            Array.iteri
              begin fun i (ip, _) ->
                let p = pget conf base ip in
                let env =
                  ("birth_witness", Vind p)
                  :: ("first", Vbool (i = 0))
                  :: env
                in
                List.iter (print_ast env ep) al
              end
              wl
          else loop events
    in
    loop (events_list conf base p)
  and print_foreach_burial_witness env al (p, _ as ep) =
    let rec loop pevents =
      match pevents with
        [] -> ()
      | (name, _, _, _, _, wl, _) :: events ->
          if name = Pevent Epers_Burial then
            Array.iteri
              begin fun i (ip, _) ->
                let p = pget conf base ip in
                let env =
                  ("burial_witness", Vind p)
                  :: ("first", Vbool (i = 0))
                  :: env
                in
                List.iter (print_ast env ep) al
              end
              wl
          else loop events
    in
    loop (events_list conf base p)
  and print_foreach_cell env al ep =
    let celll =
      match get_env "celll" env with
        Vcelll celll -> celll
      | _ -> raise Not_found
    in
    Mutil.list_iter_first
      (fun first cell ->
         let env = ("cell", Vcell cell) :: ("first", Vbool first) :: env in
         List.iter (print_ast env ep) al)
      celll
  and print_foreach_child env al ep =
    function
      Vfam (ifam, fam, (ifath, imoth, isp), _) ->
        begin match get_env "f_link" env with
          Vbool _ ->
          let baseprefix =
            match get_env "baseprefix" env with
            | Vstring baseprefix -> baseprefix
            | _ -> conf.command
          in
          let children = !GWPARAM_ITL.get_children base baseprefix ifam ifath imoth in
          List.iter begin fun ((p, _) as ep, baseprefix) ->
            let env = ("#loop", Vint 0) :: env in
            let env = ("child_link", Vind p) :: env in
            let env = ("baseprefix", Vstring baseprefix) :: env in
            let env = ("p_link", Vbool true) :: env in
            List.iter (print_ast env ep) al
          end children
        | _ ->
            let auth =
              Array.for_all
                (fun ip -> authorized_age conf base (pget conf base ip))
                (get_children fam)
            in
            let env = ("auth", Vbool auth) :: env in
            let n =
              let p =
                match get_env "p" env with
                  Vind p -> p
                | _ -> assert false
              in
              let rec loop i =
                if i = Array.length (get_children fam) then -2
                else if (get_children fam).(i) = get_iper p then i
                else loop (i + 1)
              in
              loop 0
            in
            Array.iteri
              (fun i ip ->
                 let p = pget conf base ip in
                 let env = ("#loop", Vint 0) :: env in
                 let env = ("child", Vind p) :: env in
                 let env = ("child_cnt", Vint (i + 1)) :: env in
                 let env =
                   if i = n - 1 && not (is_hidden p) then
                     ("pos", Vstring "prev") :: env
                   else if i = n then ("pos", Vstring "self") :: env
                   else if i = n + 1 && not (is_hidden p) then
                     ("pos", Vstring "next") :: env
                   else env
                 in
                 let ep = p, authorized_age conf base p in
                 List.iter (print_ast env ep) al)
              (get_children fam);

            List.iter begin fun (_, _, children) ->
              List.iter begin fun ((p, _), baseprefix, can_merge) ->
                if not can_merge then begin
                  let env = ("#loop", Vint 0) :: env in
                  let env = ("child_link", Vind p) :: env in
                  let env = ("baseprefix", Vstring baseprefix) :: env in
                  let env = ("p_link", Vbool true) :: env in
                  let ep = p, true in
                  List.iter (print_ast env ep) al
                end end children
            end (!GWPARAM_ITL.get_children' conf base (get_iper (fst ep)) fam isp)
        end
    | _ -> ()
  and print_foreach_cremation_witness env al (p, _ as ep) =
    let rec loop pevents =
      match pevents with
        [] -> ()
      | (name, _, _, _, _, wl, _) :: events ->
          if name = Pevent Epers_Cremation then
            Array.iteri
              begin fun i (ip, _) ->
                let p = pget conf base ip in
                let env =
                  ("cremation_witness", Vind p)
                  :: ("first", Vbool (i = 0))
                  :: env
                in
                List.iter (print_ast env ep) al
              end
              wl
          else loop events
    in
    loop (events_list conf base p)
  and print_foreach_death_witness env al (p, _ as ep) =
    let rec loop pevents =
      match pevents with
        [] -> ()
      | (name, _, _, _, _, wl, _) :: events ->
          if name = Pevent Epers_Death then
            Array.iteri
              begin fun i (ip, _) ->
                let p = pget conf base ip in
                let env =
                  ("death_witness", Vind p)
                  :: ("first", Vbool (i = 0))
                  :: env
                in
                List.iter (print_ast env ep) al
              end
              wl
          else loop events
    in
    loop (events_list conf base p)
  and print_foreach_descendant_level env al ep =
    let max_level =
      match get_env "max_desc_level" env with
        Vint n -> n
      | _ -> 0
    in
    let rec loop i =
      if i > max_level then ()
      else
        let env = ("level", Vint i) :: env in
        List.iter (print_ast env ep) al; loop (succ i)
    in
    loop 0
  and print_foreach_event env al (p, _ as ep) =
    let events = events_list conf base p in
    Mutil.list_iter_first
      (fun first evt ->
         let env = ("event", Vevent (p, evt)) :: env in
         let env = ("first", Vbool first) :: env in
         List.iter (print_ast env ep) al)
      events
  and print_foreach_event_witness env al (_, p_auth as ep) =
    if p_auth then
      match get_env "event" env with
        Vevent (_, (_, _, _, _, _, witnesses, _)) ->
          Array.iteri
            begin fun i (ip, wk) ->
              let p = pget conf base ip in
              let wk = Util.string_of_witness_kind conf (get_sex p) wk in
              let env =
                ("event_witness", Vind p)
                :: ("event_witness_kind", Vstring (wk :> string))
                :: ("first", Vbool (i = 0))
                :: env
              in
              List.iter (print_ast env ep) al
            end
            witnesses
      | _ -> ()
  and print_foreach_event_witness_relation env al (p, p_auth as ep) =
    let related = List.sort_uniq compare (get_related p) in
    let events_witnesses =
      let list = ref [] in
      begin let rec make_list =
        function
          ic :: icl ->
            let c = pget conf base ic in
            List.iter
              (fun (name, _, _, _, _, wl, _ as evt) ->
                 let (mem, wk) = Util.array_mem_witn conf base (get_iper p) wl in
                 if mem then
                   match name with
                     Fevent _ ->
                       if get_sex c = Male then list := (c, wk, evt) :: !list
                   | _ -> list := (c, wk, evt) :: !list)
              (events_list conf base c);
            make_list icl
        | [] -> ()
      in
        make_list related
      end;
      !list
    in
    (* On tri les témoins dans le même ordre que les évènements. *)
    let events_witnesses =
      CheckItem.sort_events
        (fun (_, _, (name, _, _, _, _, _, _)) ->
           match name with
           | Pevent n -> CheckItem.Psort n
           | Fevent n -> CheckItem.Fsort n)
        (fun (_, _, (_, date, _, _, _, _, _)) -> date)
        events_witnesses
    in
    List.iter
      (fun (p, wk, evt) ->
         if p_auth then
           let env = ("event_witness_relation", Vevent (p, evt)) :: env in
           let env =
             ( "event_witness_relation_kind"
             , Vstring (wk : Adef.safe_string :> string) )
             :: env
           in
           List.iter (print_ast env ep) al)
      events_witnesses
  and print_foreach_family env al ini_ep (p, _) =
    match get_env "p_link" env with
      Vbool _ ->
        let conf =
          match get_env "baseprefix" env with
          | Vstring baseprefix -> {conf with command = baseprefix}
          | _ -> conf
        in
        List.fold_left begin fun (prev, i) (ifam, fam, (ifath, imoth, spouse), baseprefix, _) ->
          let cpl = (ifath, imoth, get_iper spouse) in
          let vfam = Vfam (ifam, fam, cpl, true) in
          let env = ("#loop", Vint 0) :: env in
          let env = ("fam_link", vfam) :: env in
          let env = ("f_link", Vbool true) :: env in
          let env = ("is_link", Vbool true) :: env in
          let env = ("baseprefix", Vstring baseprefix) :: env in
          let env = ("family_cnt", Vint (i + 1)) :: env in
          let env =
            match prev with
            | Some vfam -> ("prev_fam", vfam) :: env
            | None -> env
          in
          List.iter (print_ast env ini_ep) al;
          (Some vfam, i + 1)
        end (None, 0) (!GWPARAM_ITL.get_families conf base p)
        |> ignore
    | _ ->
        if Array.length (get_family p) > 0 then
          begin let rec loop prev i =
            if i = Array.length (get_family p) then ()
            else
              let ifam = (get_family p).(i) in
              let fam = foi base ifam in
              let ifath = get_father fam in
              let imoth = get_mother fam in
              let ispouse = Gutil.spouse (get_iper p) fam in
              let cpl = ifath, imoth, ispouse in
              let m_auth =
                authorized_age conf base (pget conf base ifath) &&
                authorized_age conf base (pget conf base imoth)
              in
              let vfam = Vfam (ifam, fam, cpl, m_auth) in
              let env = ("#loop", Vint 0) :: env in
              let env = ("fam", vfam) :: env in
              let env = ("family_cnt", Vint (i + 1)) :: env in
              let env =
                match prev with
                  Some vfam -> ("prev_fam", vfam) :: env
                | None -> env
              in
              List.iter (print_ast env ini_ep) al; loop (Some vfam) (i + 1)
          in
            loop None 0
          end;
        List.fold_left begin fun (prev, i) (ifam, fam, (ifath, imoth, sp), baseprefix, can_merge) ->
          if can_merge then (None, i)
          else
            let cpl = (ifath, imoth, get_iper sp) in
            let vfam = Vfam (ifam, fam, cpl, true) in
            let env = ("#loop", Vint 0) :: env in
            let env = ("fam_link", vfam) :: env in
            let env = ("f_link", Vbool true) :: env in
            let env = ("is_link", Vbool true) :: env in
            let env = ("baseprefix", Vstring baseprefix) :: env in
            let env = ("family_cnt", Vint (i + 1)) :: env in
            let env =
              match prev with
              | Some vfam -> ("prev_fam", vfam) :: env
              | None -> env
            in
            List.iter (print_ast env ini_ep) al ;
            (Some vfam, i + 1)
        end (None, 0) (!GWPARAM_ITL.get_families conf base p)
        |> ignore
  and print_foreach_first_name_alias env al (p, p_auth as ep) =
    if not p_auth && is_hide_names conf p then ()
    else
      Mutil.list_iter_first
        (fun first s ->
           let env = ("first_name_alias", Vstring (sou base s)) :: env in
           let env = ("first", Vbool first) :: env in
           List.iter (print_ast env ep) al)
        (get_first_names_aliases p)
  and print_foreach_level max_lev env al (_, _ as ep) =
    let max_level =
      match get_env max_lev env with
        Vint n -> n
      | _ -> 0
    in
    let rec loop i =
      if i > max_level then ()
      else
        let env = ("level", Vint i) :: env in
        List.iter (print_ast env ep) al; loop (succ i)
    in
    loop 1
  and print_foreach_nobility_title env al (p, p_auth as ep) =
    if p_auth then
      let titles = nobility_titles_list conf base p in
      Mutil.list_iter_first
        (fun first x ->
           let env = ("nobility_title", Vtitle (p, x)) :: env in
           let env = ("first", Vbool first) :: env in
           List.iter (print_ast env ep) al)
        titles
  and print_foreach_parent env al (a, _ as ep) =
    match get_parents a with
      Some ifam ->
        let cpl = foi base ifam in
        Array.iter
          (fun iper ->
             let p = pget conf base iper in
             let env = ("parent", Vind p) :: env in
             List.iter (print_ast env ep) al)
          (get_parent_array cpl)
    | None -> ()
  and print_foreach_qualifier env al (p, p_auth as ep) =
    if not p_auth && is_hide_names conf p then ()
    else
      Mutil.list_iter_first
        (fun first nn ->
           let env = ("qualifier", Vstring (sou base nn)) :: env in
           let env = ("first", Vbool first) :: env in
           List.iter (print_ast env ep) al)
        (get_qualifiers p)
  and print_foreach_relation env al (p, p_auth as ep) =
    if p_auth then
      Mutil.list_iter_first
        (fun first r ->
           let env = ("rel", Vrel (r, None)) :: env in
           let env = ("first", Vbool first) :: env in
           List.iter (print_ast env ep) al)
        (get_rparents p)
  and print_foreach_related env al (p, p_auth as ep) =
    if p_auth then
      let list =
        let list = List.sort_uniq compare (get_related p) in
        List.fold_left
          (fun list ic ->
             let c = pget conf base ic in
             let rec loop list =
               function
                 r :: rl ->
                   begin match r.r_fath with
                     Some ip when ip = get_iper p ->
                       loop ((c, r) :: list) rl
                   | _ ->
                       match r.r_moth with
                         Some ip when ip = get_iper p ->
                           loop ((c, r) :: list) rl
                       | _ -> loop list rl
                   end
               | [] -> list
             in
             loop list (get_rparents c))
          [] list
      in
      let list =
        List.sort
          (fun (c1, _) (c2, _) ->
             let d1 =
               match Adef.od_of_cdate (get_baptism c1) with
                 None -> Adef.od_of_cdate (get_birth c1)
               | x -> x
             in
             let d2 =
               match Adef.od_of_cdate (get_baptism c2) with
                 None -> Adef.od_of_cdate (get_birth c2)
               | x -> x
             in
             match d1, d2 with
               Some d1, Some d2 -> Date.compare_date d1 d2
             | _ -> -1)
          (List.rev list)
      in
      List.iter
        (fun (c, r) ->
           let env = ("rel", Vrel (r, Some c)) :: env in
           List.iter (print_ast env ep) al)
        list
  and print_foreach_sorted_list_item env al ep =
    let list =
      match get_env "list" env with
        Vslist l -> SortedList.elements !l
      | _ -> []
    in
    let rec loop prev_item =
      function
        _ :: sll as gsll ->
          let item = Vslistlm gsll in
          let env = ("item", item) :: ("prev_item", prev_item) :: env in
          List.iter (print_ast env ep) al; loop item sll
      | [] -> ()
    in
    loop (Vslistlm []) list

  and print_foreach_sorted_listb_item env al ep =
    let list =
      match get_env "listb" env with
      | Vslist l -> SortedList.elements !l
      | _ -> []
    in
    let rec loop prev_item =
      function
      | (_ :: sll) as gsll ->
           let item = Vslistlm gsll in
           let env = ("item", item) :: ("prev_item", prev_item) :: env in
           List.iter (print_ast env ep) al;
           loop item sll
      | [] -> ()
    in loop (Vslistlm []) list
  and print_foreach_sorted_listc_item env al ep =
    let list =
      match get_env "listc" env with
      | Vslist l -> SortedList.elements !l
      | _ -> []
    in
    let rec loop prev_item =
      function
      | (_ :: sll) as gsll ->
           let item = Vslistlm gsll in
           let env = ("item", item) :: ("prev_item", prev_item) :: env in
           List.iter (print_ast env ep) al;
           loop item sll
      | [] -> ()
    in loop (Vslistlm []) list

  and print_foreach_source env al (p, p_auth as ep) =
    let rec insert_loop typ src =
      function
        (typ1, src1) :: srcl ->
          if src = src1 then (typ1 ^ ", " ^ typ, src1) :: srcl
          else (typ1, src1) :: insert_loop typ src srcl
      | [] -> [typ, src]
    in
    let insert typ src srcl =
      if src = "" then srcl
      else insert_loop (Util.translate_eval typ) src srcl
    in
    let srcl =
      if p_auth then
        let srcl = [] in
        let srcl =
          insert (transl_nth conf "person/persons" 0)
            (sou base (get_psources p)) srcl
        in
        let srcl =
          insert (transl_nth conf "birth" 0) (sou base (get_birth_src p)) srcl
        in
        let srcl =
          insert (transl_nth conf "baptism" 0) (sou base (get_baptism_src p))
            srcl
        in
        let (srcl, _) =
          Array.fold_left
            (fun (srcl, i) ifam ->
               let fam = foi base ifam in
               let isp = Gutil.spouse (get_iper p) fam in
               let sp = poi base isp in
               (* On sait que p_auth vaut vrai. *)
               let m_auth = authorized_age conf base sp in
               if m_auth then
                 let lab =
                   if Array.length (get_family p) = 1 then ""
                   else " " ^ string_of_int i
                 in
                 let srcl =
                   let src_typ = transl_nth conf "marriage/marriages" 0 in
                   insert (src_typ ^ lab) (sou base (get_marriage_src fam))
                     srcl
                 in
                 let src_typ = transl_nth conf "family/families" 0 in
                 insert (src_typ ^ lab) (sou base (get_fsources fam)) srcl,
                 i + 1
               else srcl, i + 1)
            (srcl, 1) (get_family p)
        in
        let srcl =
          insert (transl_nth conf "death" 0) (sou base (get_death_src p)) srcl
        in
        let buri_crem_lex =
          match get_burial p with
          Cremated _ -> "cremation"
          | _ -> "burial"
        in
        insert (transl_nth conf buri_crem_lex 0) (sou base (get_burial_src p))
          srcl
      else []
    in
    (* Affiche les sources et met à jour les variables "first" et "last". *)
    let rec loop first =
      function
        (src_typ, src) :: srcl ->
          let env =
            ("first", Vbool first) :: ("last", Vbool (srcl = [])) ::
            ("src_typ", Vstring src_typ) :: ("src", Vstring src) :: env
          in
          List.iter (print_ast env ep) al; loop false srcl
      | [] -> ()
    in
    loop true srcl
  and print_foreach_surname_alias env al (p, p_auth as ep) =
    if not p_auth && is_hide_names conf p then ()
    else
      Mutil.list_iter_first
        (fun first s ->
           let env = ("surname_alias", Vstring (sou base s)) :: env in
           let env = ("first", Vbool first) :: env in
           List.iter (print_ast env ep) al)
        (get_surnames_aliases p)
  and print_foreach_witness env al ep =
    function
      Vfam (_, fam, _, true) ->
      Array.iteri
        begin fun i ip ->
          let p = pget conf base ip in
          let env =
            ("witness", Vind p)
            :: ("first", Vbool (i = 0))
            :: env
          in
          List.iter (print_ast env ep) al
        end
        (get_witnesses fam)
    | _ -> ()
  and print_foreach_witness_relation env al (p, _ as ep) =
    let list =
      let list = ref [] in
      let related = List.sort_uniq compare (get_related p) in
      begin let rec make_list =
        function
          ic :: icl ->
            let c = pget conf base ic in
            if get_sex c = Male then
              Array.iter
                (fun ifam ->
                   let fam = foi base ifam in
                   if Array.mem (get_iper p) (get_witnesses fam) then
                     list := (ifam, fam) :: !list)
                (get_family (pget conf base ic));
            make_list icl
        | [] -> ()
      in
        make_list related
      end;
      !list
    in
    let list =
      List.sort
        (fun (_, fam1) (_, fam2) ->
           match
             Adef.od_of_cdate (get_marriage fam1),
             Adef.od_of_cdate (get_marriage fam2)
           with
           | Some d1, Some d2 -> Date.compare_date d1 d2
           | _ -> 0)
        list
    in
    List.iter
      (fun (ifam, fam) ->
         let ifath = get_father fam in
         let imoth = get_mother fam in
         let cpl = ifath, imoth, imoth in
         let m_auth =
           authorized_age conf base (pget conf base ifath) &&
           authorized_age conf base (pget conf base imoth)
         in
         if m_auth then
           let env = ("fam", Vfam (ifam, fam, cpl, true)) :: env in
           List.iter (print_ast env ep) al)
      list
  in
  print_foreach

let eval_predefined_apply conf env f vl =
  let vl =
    List.map
      (function
         VVstring s -> s
       | _ -> raise Not_found)
      vl
  in
  match f, vl with
    "a_of_b", [s1; s2] -> Util.translate_eval (transl_a_of_b conf s1 s2 s2)
  | "a_of_b2", [s1; s2; s3] -> Util.translate_eval (transl_a_of_b conf s1 s2 s3)
  | "a_of_b_gr_eq_lev", [s1; s2] ->
      Util.translate_eval (transl_a_of_gr_eq_gen_lev conf s1 s2 s2)
  | "add_in_sorted_list", sl ->
      begin match get_env "list" env with
        Vslist l -> l := SortedList.add sl !l; ""
      | _ -> raise Not_found
      end
  | ("add_in_sorted_listb", sl) ->
      begin match get_env "listb" env with
      | Vslist l -> l := SortedList.add sl !l; ""
      | _ -> raise Not_found
      end
  | ("add_in_sorted_listc", sl) ->
      begin match get_env "listc" env with
      | Vslist l -> l := SortedList.add sl !l; ""
      | _ -> raise Not_found
      end
  | "hexa", [s] -> Util.hexa_string s
  | "initial", [s] ->
      if String.length s = 0 then ""
      else String.sub s 0 (Utf8.next s 0)
  | "lazy_print", [v] ->
      begin match get_env "lazy_print" env with
        Vlazyp r -> r := Some v; ""
      | _ -> raise Not_found
      end
  | "min", s :: sl ->
      begin try
        let m =
          List.fold_right (fun s -> min (int_of_string s)) sl
            (int_of_string s)
        in
        string_of_int m
      with Failure _ -> raise Not_found
      end
  | "clean_html_tags", [s] ->
      (* On supprime surtout les balises qui peuvent casser la mise en page. *)
      Util.clean_html_tags s
        ["<br */?>"; "</?p>"; "</?div>"; "</?span>"; "</?pre>"]
  | _ -> raise Not_found

let gen_interp_templ ?(no_headers = false) menu title templ_fname conf base p =
  template_file := templ_fname ^ ".txt";
  let ep = p, authorized_age conf base p in
  let emal =
    match p_getint conf.env "v" with
      Some i -> i
    | None -> 120
  in
  let env =
    let sosa_ref = Util.find_sosa_ref conf base in
    if sosa_ref <> None then build_sosa_ht conf base ;
    let t_sosa =
      match sosa_ref with
      | Some p -> init_sosa_t conf base p
      | _ -> None
    in
    let desc_level_table_l =
      let dlt () = make_desc_level_table conf base emal p in Lazy.from_fun dlt
    in
    let desc_level_table_m =
      let dlt () = make_desc_level_table conf base 120 p in
      Lazy.from_fun dlt
    in
    let desc_level_table_l_save =
      let dlt () = make_desc_level_table conf base emal p in Lazy.from_fun dlt
    in
    let mal () =
      Vint (max_ancestor_level conf base (get_iper p) emal + 1)
    in
    (* Static max ancestor level *)
    let smal () =
      Vint (max_ancestor_level conf base (get_iper p) 120 + 1)
    in
    (* Sosa_ref max ancestor level *)
    let srmal () =
      match Util.find_sosa_ref conf base with
      | Some sosa_ref ->
        Vint (max_ancestor_level conf base (get_iper sosa_ref) 120 + 1)
      | _ -> Vint 0
    in
    let mcl () = Vint (max_cousin_level conf base p) in
    (* Récupère le nombre maximal de niveaux de descendance en prenant en compte les liens inter-arbres (limité à 10 générations car problématique en terme de perf). *)
    let mdl () =
      Vint (max
              (max_descendant_level base desc_level_table_l)
              (!GWPARAM_ITL.max_descendant_level conf base (get_iper p) 10)
           )
    in
    (* Static max descendant level *)
    let smdl () =
      Vint (max_descendant_level base desc_level_table_m)
    in
    let nldb () =
      let db = Gwdb.read_nldb base in
      let db = Notes.merge_possible_aliases conf db in
      Vnldb db
    in
    let all_gp () = Vallgp (get_all_generations conf base p) in
    [("p", Vind p);
     ("p_auth", Vbool (authorized_age conf base p));
     ("count", Vcnt (ref 0));
     ("count1", Vcnt (ref 0));
     ("count2", Vcnt (ref 0));
     ("list", Vslist (ref SortedList.empty));
     ("listb", Vslist (ref SortedList.empty));
     ("listc", Vslist (ref SortedList.empty));
     ("desc_mark", Vdmark (ref @@ Gwdb.dummy_marker Gwdb.dummy_iper false));
     ("lazy_print", Vlazyp (ref None));
     ("sosa",  Vsosa (ref []));
     ("sosa_ref", Vsosa_ref sosa_ref);
     ("t_sosa", Vt_sosa t_sosa);
     ("max_anc_level", Vlazy (Lazy.from_fun mal));
     ("static_max_anc_level", Vlazy (Lazy.from_fun smal));
     ("sosa_ref_max_anc_level", Vlazy (Lazy.from_fun srmal));
     ("max_cous_level", Vlazy (Lazy.from_fun mcl));
     ("max_desc_level", Vlazy (Lazy.from_fun mdl));
     ("static_max_desc_level", Vlazy (Lazy.from_fun smdl));
     ("desc_level_table", Vdesclevtab desc_level_table_l);
     ("desc_level_table_save", Vdesclevtab desc_level_table_l_save);
     ("nldb", Vlazy (Lazy.from_fun nldb));
     ("all_gp", Vlazy (Lazy.from_fun all_gp))]
  in
  if no_headers
  then
      Hutil.interp_no_header conf templ_fname
        {Templ.eval_var = eval_var conf base;
         Templ.eval_transl = eval_transl conf base;
         Templ.eval_predefined_apply = eval_predefined_apply conf;
         Templ.get_vother = get_vother; Templ.set_vother = set_vother;
         Templ.print_foreach = print_foreach conf base}
        env ep
  else if menu then
    let size =
      match Util.open_templ conf templ_fname with
        Some ic ->
          let fd = Unix.descr_of_in_channel ic in
          let stats = Unix.fstat fd in close_in ic; stats.Unix.st_size
      | None -> 0
    in
    if size = 0 then Hutil.header conf title
    else
      Hutil.interp_no_header conf templ_fname
        {Templ.eval_var = eval_var conf base;
         Templ.eval_transl = eval_transl conf base;
         Templ.eval_predefined_apply = eval_predefined_apply conf;
         Templ.get_vother = get_vother; Templ.set_vother = set_vother;
         Templ.print_foreach = print_foreach conf base}
        env ep
  else
    Hutil.interp conf templ_fname
      {Templ.eval_var = eval_var conf base;
       Templ.eval_transl = eval_transl conf base;
       Templ.eval_predefined_apply = eval_predefined_apply conf;
       Templ.get_vother = get_vother; Templ.set_vother = set_vother;
       Templ.print_foreach = print_foreach conf base}
      env ep

let interp_templ ?no_headers = gen_interp_templ ?no_headers false (fun _ -> ())
let interp_templ_with_menu = gen_interp_templ true
let interp_notempl_with_menu title templ_fname conf base p =
  (* On envoie le header car on n'est pas dans un template (exple: merge). *)
  Hutil.header_without_page_title conf title;
  gen_interp_templ true title templ_fname conf base p

(* Main *)

let print ?no_headers conf base p =
  let passwd =
    if conf.wizard || conf.friend then None
    else
      let src =
        match get_parents p with
        | Some ifam -> sou base (get_origin_file (foi base ifam))
        | None -> ""
      in
      try Some (src, List.assoc ("passwd_" ^ src) conf.base_env) with
        Not_found -> None
  in
  match passwd with
  | Some (src, passwd)
    when is_that_user_and_password conf.auth_scheme "" passwd = false ->
    Util.unauthorized conf src
  | _ -> interp_templ ?no_headers "perso" conf base p

let limit_by_tree conf =
  match Opt.map int_of_string (List.assoc_opt "max_anc_tree" conf.base_env) with
  | Some x -> max 1 x
  | None -> 7

let print_ancestors_dag conf base v p =
  let v = min (limit_by_tree conf) v in
  let set =
    let rec loop set lev ip =
      let set = Dag.Pset.add ip set in
      if lev <= 1 then set
      else
        match get_parents (pget conf base ip) with
          Some ifam ->
            let cpl = foi base ifam in
            let set = loop set (lev - 1) (get_mother cpl) in
            loop set (lev - 1) (get_father cpl)
        | None -> set
    in
    loop Dag.Pset.empty v (get_iper p)
  in
  let elem_txt p = DagDisplay.Item (p, Adef.safe "") in
  (* Récupère les options d'affichage. *)
  let options = Util.display_options conf in
  let vbar_txt ip =
    let p = pget conf base ip in
    commd conf
    ^^^ "m=A&t=T&dag=on&v="
    ^<^ string_of_int v
    ^<^ "&"
    ^<^ options
    ^^^ "&"
    ^<^ acces conf base p
  in
  let page_title =
    Util.transl conf "tree"
    |> Utf8.capitalize_fst
    |> Adef.safe
  in
  DagDisplay.make_and_print_dag conf base elem_txt vbar_txt true set [] page_title (Adef.escaped "")

let print_ascend conf base p =
  match
    p_getenv conf.env "t", p_getenv conf.env "dag", p_getint conf.env "v"
  with
    Some "T", Some "on", Some v -> print_ancestors_dag conf base v p
  | _ ->
      let templ =
        match p_getenv conf.env "t" with
          Some ("E" | "F" | "H" | "L") -> "anclist"
        | Some ("D" | "G" | "M" | "N" | "P" | "X" | "Y" | "Z") -> "ancsosa"
        | Some ("A" | "C" | "T") -> "anctree"
        | _ -> "ancmenu"
      in
      interp_templ templ conf base p

let print_what_links conf base p =
  if authorized_age conf base p then
    let key =
      let fn = Name.lower (sou base (get_first_name p)) in
      let sn = Name.lower (sou base (get_surname p)) in fn, sn, get_occ p
    in
    let db = Gwdb.read_nldb base in
    let db = Notes.merge_possible_aliases conf db in
    let pgl = links_to_ind conf base db key in
    let title h =
      transl conf "linked pages"
      |> Utf8.capitalize_fst
      |> Output.print_sstring conf ;
      Util.transl conf ":"
      |> Output.print_sstring conf ;
      if h
      then Output.print_string conf (simple_person_text conf base p true)
      else begin
        Output.print_sstring conf {|<a href="|} ;
        Output.print_string conf (commd conf) ;
        Output.print_string conf (acces conf base p) ;
        Output.print_sstring conf {|">|} ;
        Output.print_string conf (simple_person_text conf base p true) ;
        Output.print_sstring conf {|</a>|}
      end
    in
    Hutil.header conf title;
    Hutil.print_link_to_welcome conf true;
    NotesDisplay.print_linked_list conf base pgl;
    Hutil.trailer conf
  else Hutil.incorrect_request conf
