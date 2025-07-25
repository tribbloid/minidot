(*
FSub (F<:)
T ::= Top | X | T -> T | Forall Z <: T. T^Z
t ::= x | lambda x:T.t | Lambda X<:T.t | t t | t [T]
*)

(* semantic equality big-step / small-step *)

Require Export SfLib.

Require Export Arith.EqNat.
Require Export Arith.Le.
Require Import Coq.Program.Equality.
Require Import Lia.
Require Import NPeano.

(* ### Syntax ### *)

Definition id := nat.

Inductive ty : Type :=
| TTop : ty
| TFun : ty -> ty -> ty
| TAll : ty -> ty -> ty
| TVarF : id -> ty (* free type variable, in concrete environment *)
| TVarH : id -> ty (* free type variable, in abstract environment  *)
| TVarB : id -> ty (* locally-bound type variable *)
.

Inductive tm : Type :=
| tvar : id -> tm
| tabs : ty -> tm -> tm
| tapp : tm -> tm -> tm
| ttabs : ty -> tm -> tm
| ttapp : tm -> ty -> tm
| tty: ty -> tm
.

Inductive binding {X: Type} :=
| bind_tm : X -> binding
| bind_ty : X -> binding
.

Inductive vl : Type :=
(* a closure for a term abstraction *)
| vabs : venv (*H*) -> ty -> tm -> vl
(* a closure for a type abstraction *)
| vtabs : venv (*H*) -> ty -> tm -> vl
(* a closure over a type *)
| vty : venv (*H*) -> ty -> vl
with venv : Type := (* need to recurse structurally, hence don't use built-in list *)
| vnil: venv
| vcons: vl -> venv -> venv
.

Definition tenv := list (@binding ty). (* Gamma environment: static *)
(*Definition venv := list vl. (* H environment: run-time *) *)
Definition aenv := list (venv*ty). (* J environment: abstract at run-time *)

(* ### Representation of Bindings ### *)

(* An environment is a list of values, indexed by decrementing ids. *)

Fixpoint lengthr (l : venv) : nat :=
  match l with
    | vnil => O
    | vcons a  l' =>
      S (lengthr l')
  end.


Fixpoint indexr (n : id) (l : venv) : option vl :=
  match l with
    | vnil => None
    | vcons a  l' =>
      if (Nat.eqb n (lengthr l')) then Some a else indexr n l'
  end.


Inductive closed: nat(*B*) -> nat(*H*) -> nat(*F*) -> ty -> Prop :=
| cl_top: forall i j k,
    closed i j k TTop
| cl_fun: forall i j k T1 T2,
    closed i j k T1 ->
    closed i j k T2 ->
    closed i j k (TFun T1 T2)
| cl_all: forall i j k T1 T2,
    closed i j k T1 ->
    closed (S i) j k T2 ->
    closed i j k (TAll T1 T2)
| cl_sel: forall i j k x,
    k > x ->
    closed i j k (TVarF x)
| cl_selh: forall i j k x,
    j > x ->
    closed i j k (TVarH x)
| cl_selb: forall i j k x,
    i > x ->
    closed i j k (TVarB x)
.

(* open define a locally-nameless encoding wrt to TVarB type variables. *)
(* substitute type u for all occurrences of (TVarB k) *)
Fixpoint open_rec (k: nat) (u: ty) (T: ty) { struct T }: ty :=
  match T with
    | TTop        => TTop
    | TFun T1 T2  => TFun (open_rec k u T1) (open_rec k u T2)
    | TAll T1 T2  => TAll (open_rec k u T1) (open_rec (S k) u T2)
    | TVarF x => TVarF x
    | TVarH i => TVarH i
    | TVarB i => if Nat.eqb k i then u else TVarB i
  end.

Definition open u T := open_rec O u T.

(* Locally-nameless encoding with respect to varH variables. *)
Fixpoint subst (U : ty) (T : ty) {struct T} : ty :=
  match T with
    | TTop         => TTop
    | TFun T1 T2   => TFun (subst U T1) (subst U T2)
    | TAll T1 T2   => TAll (subst U T1) (subst U T2)
    | TVarB i      => TVarB i
    | TVarF i      => TVarF i
    | TVarH i => if Nat.eqb i O then U else TVarH (pred i)
  end.

Definition liftb (f: ty -> ty) b :=
  match b with
    | bind_tm T => bind_tm (f T)
    | bind_ty T => bind_ty (f T)
  end.

Definition substb (U: ty) := liftb (subst U).

Fixpoint nosubst (T : ty) {struct T} : Prop :=
  match T with
    | TTop         => True
    | TFun T1 T2   => nosubst T1 /\ nosubst T2
    | TAll T1 T2   => nosubst T1 /\ nosubst T2
    | TVarB i      => True
    | TVarF i      => True
    | TVarH i      => i <> O
  end.



(* ### Evaluation (Big-Step Semantics) ### *)

(*
None             means timeout
Some None        means stuck
Some (Some v))   means result v
*)

(* Environment-based evaluator *)

Fixpoint teval(n: nat)(env: venv)(t: tm){struct n}: option (option vl) :=
  match n with
    | O => None
    | S n =>
      match t with
        | tty T        => Some (Some (vty env T))
        | tvar x       => Some (indexr x env)
        | tabs T y     => Some (Some (vabs env T y))
        | ttabs T y    => Some (Some (vtabs env T y))
        | tapp ef ex   =>
          match teval n env ex with
            | None => None
            | Some None => Some None
            | Some (Some vx) =>
              match teval n env ef with
                | None => None
                | Some None => Some None
                | Some (Some (vtabs _ _ _)) => Some None
                | Some (Some (vty _ _)) => Some None
                | Some (Some (vabs env2 _ ey)) =>
                  teval n (vcons vx env2) ey
              end
          end
        | ttapp ef ex   =>
          match teval n env ef with
            | None => None
            | Some None => Some None
            | Some (Some (vabs _ _ _)) => Some None
            | Some (Some (vty _ _)) => Some None
            | Some (Some (vtabs env2 T ey)) =>
              teval n (vcons (vty env ex) env2) ey
          end
      end
  end.

(* Substitution-based evaluator *)


Fixpoint shift_ty (u:nat) (T : ty) {struct T} : ty :=
  match T with
    | TTop        => TTop
    | TFun T1 T2  => TFun (shift_ty u T1) (shift_ty u T2)
    | TAll T1 T2  => TAll (shift_ty u T1) (shift_ty u T2)
    | TVarF i     => TVarF i
    | TVarH i     => TVarH (i + u)
    | TVarB i     => TVarB i
  end.


Fixpoint shift_tm (u:nat) (T : tm) {struct T} : tm :=
  match T with
    | tvar i      => tvar (i + u)
    | tabs T1 t   => tabs (shift_ty u T1) (shift_tm u t)
    | tapp t1 t2  => tapp (shift_tm u t1) (shift_tm u t2)
    | ttabs T1 t  => ttabs (shift_ty u T1) (shift_tm u t) 
    | ttapp t1 T2 => ttapp (shift_tm u t1) (shift_ty u T2)
    | tty T       => tty (shift_ty u T)
  end.

Definition et t := match t with
                     | tty T => T
                     | _ => TTop
                   end.

Fixpoint subst_tm (u:tm) (T : tm) {struct T} : tm :=
  match T with
    | tvar i => if Nat.eqb i O then u else tvar (pred i)
    | tabs T1 t   => tabs (subst (et u) T1) (subst_tm (shift_tm (S O) u) t)
    | tapp t1 t2  => tapp (subst_tm u t1) (subst_tm u t2)
    | ttabs T1 t  => ttabs (subst (et u) T1) (subst_tm (shift_tm (S O) u) t)
    | ttapp t1 T2 => ttapp (subst_tm u t1) (subst (et u) T2)
    | tty T       => tty (subst (et u) T)
  end.

Fixpoint subst_ty (u:ty) (T : tm) {struct T} : tm :=
  match T with
    | tvar i => if Nat.eqb i O then (tty u) else tvar (pred i)
    | tabs T1 t   => tabs (subst u T1) (subst_ty (shift_ty (S O) u) t)
    | tapp t1 t2  => tapp (subst_ty u t1) (subst_ty u t2)
    | ttabs T1 t  => ttabs (subst u T1) (subst_ty (shift_ty (S O) u) t)
    | ttapp t1 T2 => ttapp (subst_ty u t1) (subst u T2)
    | tty T       => tty (subst u T)
  end.

Fixpoint tevals(n: nat)(t: tm){struct n}: option (option tm) :=
  match n with
    | O => None
    | S n =>
      match t with
        | tty T        => Some (Some (tty T))
        | tvar x       => Some None
        | tabs T y     => Some (Some (tabs T y))
        | ttabs T y    => Some (Some (ttabs T y))
        | tapp ef ex   =>
          match tevals n ex with
            | None => None
            | Some None => Some None
            | Some (Some vx) =>
              match tevals n ef with
                | None => None
                | Some None => Some None
                | Some (Some (tty T)) => Some None
                | Some (Some (tvar _)) => Some None
                | Some (Some (tapp _ _)) => Some None
                | Some (Some (ttapp _ _)) => Some None
                | Some (Some (ttabs _ _)) => Some None
                | Some (Some (tabs _ ey)) =>
                  tevals n (subst_tm vx ey)
              end
          end
        | ttapp ef ex   =>
          match tevals n ef with
            | None => None
            | Some None => Some None
            | Some (Some (tty T)) => Some None
            | Some (Some (tvar _)) => Some None
            | Some (Some (tapp _ _)) => Some None
            | Some (Some (ttapp _ _)) => Some None
            | Some (Some (tabs _ _)) => Some None
            | Some (Some (ttabs T ey)) =>
              tevals n (subst_ty ex ey)
          end
      end
  end.




(* ### Evaluation (Small-Step Semantics) ### *)

Inductive value : tm -> Prop :=
| V_Abs : forall T t,
    value (tabs T t)
| V_TAbs : forall T t,
    value (ttabs T t)
| V_Ty : forall T,
    value (tty T)
.


Inductive step : tm -> tm -> Prop :=
| ST_AppAbs : forall v T1 t12,
    value v ->
    step (tapp (tabs T1 t12) v) (subst_tm v t12)
| ST_App1 : forall t1 t1' t2,
    step t1 t1' ->
    step (tapp t1 t2) (tapp t1' t2)
| ST_App2 : forall f t2 t2',
    value f ->
    step t2 t2' ->
    step (tapp f t2) (tapp f t2')
| ST_TAppAbs : forall T1 t12 T2,
    step (ttapp (ttabs T1 t12) T2) (subst_ty T2 t12)
| ST_TApp1 : forall t1 t1' t2,
    step t1 t1' ->
    step (ttapp t1 t2) (ttapp t1' t2)
.


Inductive mstep : nat -> tm -> tm -> Prop :=
| MST_Z : forall t,
    mstep O t t
| MST_S: forall n t1 t2 t3,
    step t1 t2 ->
    mstep n t2 t3 ->
    mstep (S n) t1 t3
.



(* automation *)

Hint Constructors venv : core.
Hint Unfold tenv : core.

Hint Unfold open : core.
Hint Unfold indexr : core.
Hint Unfold length : core.

Hint Constructors ty : core.
Hint Constructors tm : core.
Hint Constructors vl : core.

Hint Constructors closed : core.

Hint Constructors option : core.
Hint Constructors list : core.

Hint Resolve ex_intro : core.



(* ### Euivalence big-step env <-> big-step subst ### *)

Fixpoint subst_ty_all n venv t {struct venv} :=
  match venv with
    | vnil                       => t
    | vcons (vabs venv0 T y) tl  => subst TTop (subst_ty_all (S n) tl t) (* use TTop as placeholder *) 
    | vcons (vtabs venv0 T y) tl => subst TTop (subst_ty_all (S n) tl t) (* use TTop as placeholder *)
    | vcons (vty venv0 T) tl     =>
      subst (shift_ty n (subst_ty_all O venv0 T)) (subst_ty_all (S n) tl t)
  end.


Fixpoint subst_tm_all n venv t {struct venv} :=
  match venv with
    | vnil => t
    | vcons (vabs venv0 T y) tl =>
      subst_tm (shift_tm n (tabs (subst_ty_all O venv0 T) (subst_tm_all (S O) venv0 y))) (subst_tm_all (S n) tl t)
    | vcons (vtabs venv0 T y) tl =>
      subst_tm (shift_tm n (ttabs (subst_ty_all O venv0 T) (subst_tm_all (S O) venv0 y))) (subst_tm_all (S n) tl t)
    | vcons (vty venv0 T) tl =>
      subst_ty (shift_ty n (subst_ty_all O venv0 T)) (subst_tm_all (S n) tl t)
  end.


Definition subst_tm_res t :=
  match t with
    | None => None
    | Some None => Some None
    | Some (Some (vabs venv0 T y)) => Some (Some ((tabs (subst_ty_all O venv0 T) (subst_tm_all (S O) venv0 y))))
    | Some (Some (vtabs venv0 T y)) => Some (Some ((ttabs (subst_ty_all O venv0 T) (subst_tm_all (S O) venv0 y))))
    | Some (Some (vty venv0 T)) => Some (Some (tty (subst_ty_all O venv0 T)))
  end.



Lemma idx_miss: forall env i l,
  i >= lengthr env ->
  indexr i env = None /\ subst_tm_all l env (tvar i) = (tvar (i - (lengthr env))).
Proof.
  intros env. induction env.
  - intros. simpl in H. simpl. 
    assert (i - O = i). lia. rewrite H0. eauto.
  - intros. simpl in H. simpl.
    destruct (IHenv i (S l)) as [A B]. lia.
    rewrite B. simpl. 
    assert (Nat.eqb (i - lengthr env) O = false). apply Nat.eqb_neq. lia.
    assert (Nat.eqb i (lengthr env) = false). apply Nat.eqb_neq. lia.
    rewrite H0. rewrite H1. 
    assert (pred (i - lengthr env) = i - S (lengthr env)). lia.
    rewrite H2.

    destruct v; try destruct v; eauto.
Qed. 

Lemma idx_miss1: forall env i l,
  i >= lengthr env ->
  subst_tm_all l env (tvar i) = (tvar (i - (lengthr env))).
Proof.
  intros env. eapply idx_miss; eauto. 
Qed. 

Lemma shiftz_id_ty: forall t,
  shift_ty O t = t.
Proof.
  intros. induction t; simpl; eauto; try rewrite IHt; try rewrite IHt1; try rewrite IHt2; eauto.
Qed.

Lemma shiftz_id: forall t,
  shift_tm O t = t.
Proof.
  intros. induction t; simpl; eauto; try rewrite IHt; try rewrite IHt1; try rewrite IHt2; eauto; try rewrite shiftz_id_ty; eauto.
Qed.


Lemma shift_add_ty: forall t l1 l2,
  shift_ty l1 (shift_ty l2 t) = shift_ty (l2 + l1) t.
Proof.
  intros. induction t; simpl; eauto; try rewrite IHt; try rewrite IHt1; try rewrite IHt2; eauto.
  rewrite plus_assoc. eauto.
Qed.

Lemma shift_add: forall t l1 l2,
  shift_tm l1 (shift_tm l2 t) = shift_tm (l2 + l1) t.
Proof.
  intros. induction t; simpl; eauto; try rewrite IHt; try rewrite IHt1; try rewrite IHt2; eauto; try rewrite shift_add_ty; eauto.
  rewrite plus_assoc. eauto.
Qed.

Lemma subst_shift_id_ty: forall t u l,
  subst u (shift_ty (S l) t) = shift_ty l t.
Proof.
  intros t. induction t; intros; simpl; eauto.
  - rewrite IHt1. rewrite IHt2. eauto.
  - rewrite IHt1. rewrite IHt2. eauto. 
  - assert (Nat.eqb (i + S l) O = false). apply Nat.eqb_neq. lia. rewrite H.
    assert (pred (i + S l) = i + l). lia. rewrite H0; eauto.
Qed.

Lemma subst_shift_id_ty1: forall t u l,
  subst_ty u (shift_tm (S l) t) = shift_tm l t.
Proof.
  intros t. induction t; intros; simpl; eauto.
  - assert (Nat.eqb (i + S l) O = false). apply Nat.eqb_neq. lia. rewrite H.
    assert (pred (i + S l) = i + l). lia. rewrite H0; eauto.
  - rewrite IHt. rewrite subst_shift_id_ty. eauto. 
  - rewrite IHt1. rewrite IHt2. eauto. 
  - rewrite IHt. rewrite subst_shift_id_ty. eauto. 
  - rewrite IHt. rewrite subst_shift_id_ty. eauto.
  - rewrite subst_shift_id_ty. eauto. 
Qed.

Lemma subst_shift_id: forall t u l,
  subst_tm u (shift_tm (S l) t) = shift_tm l t.
Proof.
  intros t. induction t; intros; simpl; eauto.
  - assert (Nat.eqb (i + S l) O = false). apply Nat.eqb_neq. lia. rewrite H.
    assert (pred (i + S l) = i + l). lia. rewrite H0; eauto.
  - rewrite IHt. rewrite subst_shift_id_ty. eauto. 
  - rewrite IHt1. rewrite IHt2. eauto. 
  - rewrite IHt. rewrite subst_shift_id_ty. eauto. 
  - rewrite IHt. rewrite subst_shift_id_ty. eauto.
  - rewrite subst_shift_id_ty. eauto. 
Qed.

Lemma subst_ty_tm: forall t u,
  subst_tm (tty u) t = subst_ty u t.
Proof.
  intros t. induction t; intros; simpl; eauto.
  - rewrite IHt. eauto. 
  - rewrite IHt1. rewrite IHt2. eauto.
  - rewrite IHt. eauto.
  - rewrite IHt. eauto.
Qed. 



Lemma idx_miss2: forall env i v l,
  i < lengthr env ->
  subst_tm_all l (vcons v env) (tvar i) = subst_tm_all l env (tvar i).
Proof.
  intros env. induction env.
  - intros. inversion H.
  - intros. simpl in H.
    case_eq (Nat.eqb i (lengthr env)); intros E.
    + 
      assert (Nat.eqb (i - lengthr env) O = true) as E1.
      apply Nat.eqb_eq. apply Nat.eqb_eq in E. lia.

      simpl. rewrite idx_miss1. rewrite idx_miss1. simpl. rewrite E1.

      destruct v0; destruct v; eauto.

      simpl. rewrite subst_shift_id. eauto. rewrite subst_shift_id_ty. eauto.
      simpl. rewrite subst_shift_id. eauto. rewrite subst_shift_id_ty. eauto.
      simpl. rewrite subst_shift_id_ty. eauto.
      simpl. rewrite subst_shift_id. eauto. rewrite subst_shift_id_ty. eauto.
      simpl. rewrite subst_shift_id. eauto. rewrite subst_shift_id_ty. eauto.
      simpl. rewrite subst_shift_id_ty. eauto. 

      simpl. rewrite subst_shift_id_ty. eauto. rewrite shift_add_ty. rewrite plus_comm.
      rewrite subst_shift_id_ty1. eauto. 
      simpl. rewrite subst_shift_id_ty. eauto. rewrite shift_add_ty. rewrite plus_comm. 
      rewrite subst_shift_id_ty1. eauto. 
      simpl. rewrite subst_shift_id_ty. eauto. 
      
      apply Nat.eqb_eq in E. lia.
      apply Nat.eqb_eq in E. lia.

    + assert (i < lengthr env). apply Nat.eqb_neq in E. lia.
      remember (vcons v env) as env1. simpl.
      subst env1. rewrite IHenv. rewrite IHenv.

      destruct v0.
      eapply (IHenv i (vabs v0 t t0)). eauto.
      eapply (IHenv i (vtabs v0 t t0)). eauto.
      eapply (IHenv i (vty v0 t)). eauto.
      eauto.
      eauto. 
Qed. 


Lemma idx_hit: forall env i,
  i < lengthr env ->
  subst_tm_res (Some (indexr i env)) = Some (Some (subst_tm_all O env (tvar i))).
Proof.
  intros env. induction env.
  - intros. inversion H.
  - intros.
    simpl in H. simpl.
    case_eq (Nat.eqb i (lengthr env)); intros E.
    + apply Nat.eqb_eq in E.
      rewrite idx_miss1. subst i. simpl.      
      assert (Nat.eqb (lengthr env - lengthr env) O = true). apply Nat.eqb_eq. lia.
      rewrite H0.
      assert (Nat.eqb (lengthr env) (lengthr env) = true). apply Nat.eqb_eq. lia.
      destruct v.  
      rewrite shiftz_id. rewrite shiftz_id_ty. eauto.
      rewrite shiftz_id. rewrite shiftz_id_ty. eauto.
      rewrite shiftz_id_ty. eauto.
      lia.
    + assert (i <> lengthr env). apply Nat.eqb_neq. eauto.
      assert (i < lengthr env). lia.

      specialize (IHenv _ H1). 
      rewrite <-(idx_miss2 env _ v) in IHenv . simpl in IHenv. eauto. eauto.
Qed.

(* proof of equivalence *)

Theorem big_env_subst: forall n env e1 e2,
  subst_tm_all O env e1 = e2 ->
  subst_tm_res (teval n env e1) = (tevals n e2).
Proof.   
  intros n. induction n.
  (* z *) intros. simpl. eauto.
  (* S n *) intros.
  destruct e1; simpl; eauto.
  - (* var *)
    assert (i < lengthr env \/ i >= lengthr env) as L. lia.
    destruct L as [L|L].
    + (* hit *) 
      simpl in H.
      specialize (idx_hit env i L). intros IX. rewrite H in IX.
      remember (indexr i env). destruct o. 
      * simpl in IX. rewrite IX. destruct v; inversion IX; eauto.
      * inversion IX. 
    +
      specialize (idx_miss env i O L). intros IX. rewrite H in IX.
      destruct IX as [A B]. rewrite A. rewrite B. eauto. 

  - (* tabs *)
    assert (forall env l,
              subst_tm_all l env (tabs t e1) = 
              (tabs (subst_ty_all l env t) (subst_tm_all (S l) env e1))) as REC. {
    intros env0. induction env0; intros.
    simpl. eauto.
    simpl. destruct v; rewrite IHenv0; simpl; eauto;
    try rewrite shift_add; rewrite shift_add_ty; rewrite plus_comm; eauto. }

    rewrite REC in H. subst e2. eauto. 
  - (* tapp *)
    assert (forall env l,
              subst_tm_all l env (tapp e1_1 e1_2) = 
              (tapp (subst_tm_all l env e1_1) (subst_tm_all l env e1_2))) as REC. {
    intros env0. induction env0; intros.
    simpl. eauto.
    simpl. destruct v; rewrite IHenv0; simpl; eauto. }

    rewrite REC in H. subst e2.
    
    assert (subst_tm_res (teval n env e1_2) = tevals n (subst_tm_all O env e1_2)) as HF. eapply IHn; eauto.
    assert (subst_tm_res (teval n env e1_1) = tevals n (subst_tm_all O env e1_1)) as HX. eapply IHn; eauto.
    rewrite <-HF. rewrite <-HX. simpl. 

    remember ((teval n env e1_2)) as A.
    destruct A as [[|]|]; simpl.
    * remember ((teval n env e1_1)) as B.
      destruct B as [[|]|]; simpl. 
      { destruct v0; destruct v; simpl; eauto.
        eapply IHn. simpl. rewrite shiftz_id. rewrite shiftz_id_ty. eauto.
        eapply IHn. simpl. rewrite shiftz_id. rewrite shiftz_id_ty. eauto.
        eapply IHn. simpl. rewrite subst_ty_tm. rewrite shiftz_id_ty. eauto. 
      }
      destruct v; eauto.
      destruct v; eauto.  
    * eauto.
    * eauto.
  - (* ttabs *)
    assert (forall env l,
              subst_tm_all l env (ttabs t e1) = 
              (ttabs (subst_ty_all l env t) (subst_tm_all (S l) env e1))) as REC. {
    intros env0. induction env0; intros.
    simpl. eauto.
    simpl. destruct v; rewrite IHenv0; simpl; eauto;
    try rewrite shift_add; rewrite shift_add_ty; rewrite plus_comm; eauto. }

    rewrite REC in H. subst e2. eauto.
  - (* ttapp *)
    assert (forall env l,
              subst_tm_all l env (ttapp e1 t) = 
              (ttapp (subst_tm_all l env e1) (subst_ty_all l env t))) as REC. {
    intros env0. induction env0; intros.
    simpl. eauto.
    simpl. destruct v; rewrite IHenv0; simpl; eauto. }

    rewrite REC in H. subst e2.
    
    assert (subst_tm_res (teval n env e1) = tevals n (subst_tm_all O env e1)) as HX. eapply IHn; eauto.
    rewrite <-HX. simpl. 

    remember ((teval n env e1)) as B.
    destruct B as [[?|]|]; simpl. 
    { destruct v; simpl; eauto.
      eapply IHn. simpl. rewrite shiftz_id_ty. eauto. }
    eauto. eauto. 
  - (* dummy *)
    assert (forall env l T,
              subst_tm_all l env (tty T) = 
              (tty (subst_ty_all l env T))) as REC. {
      intros env0. induction env0; intros.
      simpl. eauto.
      simpl. destruct v; rewrite IHenv0; simpl; eauto;
             try rewrite shift_add; rewrite shift_add_ty; rewrite plus_comm; eauto. }

    rewrite REC in H. subst e2. eauto. 
Qed.



(* ### Equivalence big-step subst <-> small-step subst ### *)

Lemma app_inv: forall nu t1 t2 t3,
  tevals nu (tapp t1 t2) = Some (Some t3) ->
  exists T ty v2 nv, nu = S nv /\
                     tevals nv t1 = Some (Some (tabs T ty)) /\
                     tevals nv t2 = Some (Some v2) /\
                     tevals nv (subst_tm v2 ty) = Some (Some t3).
Proof.
  intros. destruct nu. inversion H. 
  simpl in H.
  remember (tevals nu t2) as rx.
  destruct rx. destruct o.
  remember (tevals nu t1) as rf.
  destruct rf. destruct o.

  destruct t0; inversion H; repeat eexists; eauto.
  inversion H. inversion H. inversion H. inversion H.
Qed.

Lemma tapp_inv: forall nu t1 t2 t3,
  tevals nu (ttapp t1 t2) = Some (Some t3) ->
  exists T ty nv, nu = S nv /\
                     tevals nv t1 = Some (Some (ttabs T ty)) /\
                     tevals nv (subst_ty t2 ty) = Some (Some t3).
Proof.
  intros. destruct nu. inversion H. 
  simpl in H.
  remember (tevals nu t1) as rf.
  destruct rf. destruct o.

  destruct t; inversion H; repeat eexists; eauto.
  inversion H. inversion H. 
Qed.


Lemma eval_stable: forall n t1 v j,
  tevals n t1 = Some v ->
  j >= n ->
  tevals j t1 = Some v.
Proof.
  intros n. induction n; intros. inversion H.
  destruct j. inversion H0.
  destruct t1; eauto.
  - simpl in H. simpl. 
    remember (tevals n t1_2) as rx.
      destruct rx. destruct o.
      rewrite (IHn _ (Some t)). 
      remember (tevals n t1_1) as rf.
      destruct rf. destruct o.
      rewrite (IHn _ (Some t0)).
      destruct t0; eauto; eapply IHn; eauto; lia.
      destruct t0; eauto; eapply IHn; eauto; lia.
      lia.
      rewrite (IHn _ None). eauto. eauto. lia.
      inversion H. 
      
      eauto. lia.
      inversion H. rewrite (IHn _ None). eauto. eauto. lia.
      inversion H.
 - simpl in H. simpl. 
    remember (tevals n t1) as rf.
      destruct rf. destruct o.
      rewrite (IHn _ (Some t0)). 
      destruct t0; eauto; eapply IHn; eauto; lia.
      destruct t0; eauto; eapply IHn; eauto; lia.
      lia.
      rewrite (IHn _ None). eauto. eauto. lia.
      inversion H. 
Qed.



Lemma value_eval: forall t1,
   value t1 ->
   forall nu, nu >= (S O) -> tevals nu t1 = Some (Some t1).
Proof.
  intros. destruct nu. inversion H0. inversion H; eauto.
Qed.


Lemma step_eval: forall t1 t2,
  step t1 t2 ->
  forall t3 nu, tevals nu t2 = Some (Some t3) ->
  tevals (S nu) t1 = Some (Some t3).
Proof.
  intros ? ? ?. induction H; intros.
  - (* AppAbs *)
    simpl.
    assert (nu >= (S O)). destruct nu. inversion H0. lia.
    rewrite (value_eval v).
    rewrite (value_eval (tabs T1 t12)).
    eapply H0; lia. constructor.
    eauto. eauto. eauto.
  - (* App1 *)
    simpl. eapply app_inv in H0.
    repeat destruct H0 as [x H0].
    destruct H0 as [N [E1 [E2 E3]]].
    eapply IHstep in E1.
    eapply eval_stable in E2.
    rewrite E1. rewrite E2. eapply eval_stable. eapply E3. eauto. eauto.
  - (* App2 *)
    simpl. eapply app_inv in H1.
    repeat destruct H1 as [x H1].
    destruct H1 as [N [E1 [E2 E3]]].
    eapply IHstep in E2.
    eapply eval_stable in E1.
    rewrite E1. rewrite E2. eapply eval_stable. eapply E3. eauto. eauto.
  - (* TAppAbs *)
    simpl.
    assert (nu >= (S O)). destruct nu. inversion H. lia.
    rewrite (value_eval (ttabs T1 t12)).
    eapply H; lia. constructor.
    eauto. 
  - (* App1 *)
    simpl. eapply tapp_inv in H0.
    repeat destruct H0 as [x H0].
    destruct H0 as [N [E1 E2]].
    eapply IHstep in E1.
    eapply eval_stable in E2.
    rewrite E1. rewrite E2. eauto. eauto.
Qed.
    
  
(* proof of equivalence: small-step implies big-step *)

Theorem small_to_big: forall n t1 t2,
   mstep n t1 t2 -> value t2 ->
   exists ns, tevals ns t1 = Some (Some t2).
Proof.
  intros n. induction n.
  (* z *)
  intros. inversion H; subst. 
  exists (S O). eapply value_eval; eauto.
  (* S n *) 
  intros. inversion H; subst.
  eapply IHn in H3. destruct H3.
  exists (S x). eapply step_eval; eauto.
  eauto. 
Qed.


(* proof of equivalence: big-step implies small-step *)

Lemma ms_app1 : forall n t1 t1' t2,
     mstep n t1 t1' ->
     mstep n (tapp t1 t2) (tapp t1' t2).
Proof.
  intros. induction H. constructor.
  econstructor. eapply ST_App1; eauto. eauto.
Qed.

Lemma ms_app2 : forall n t1 t2 t2',
     value t1 ->
     mstep n t2 t2' ->
     mstep n (tapp t1 t2) (tapp t1 t2').
Proof.
  intros. induction H0. constructor.
  econstructor. apply ST_App2; eauto. eauto.
Qed.

Lemma ms_tapp1 : forall n t1 t1' t2,
     mstep n t1 t1' ->
     mstep n (ttapp t1 t2) (ttapp t1' t2).
Proof.
  intros. induction H. constructor.
  econstructor. eapply ST_TApp1; eauto. eauto.
Qed.



Lemma ms_trans : forall n1 n2 t1 t2 t3,
     mstep n1 t1 t2 ->
     mstep n2 t2 t3 ->
     mstep (n1 + n2) t1 t3.
Proof.
  intros. induction H. eauto. 
  econstructor. eauto. eauto. 
Qed.


Theorem big_to_small: forall n t1 t2,
   tevals n t1 = Some (Some t2) ->
   exists ns, value t2 /\ mstep ns t1 t2.
Proof.
  intros n. induction n; intros. inversion H. destruct t1.
  - simpl in H. inversion H.
  - simpl in H. inversion H. eexists. split; constructor.
  - eapply app_inv in H. repeat destruct H as [? H].
    destruct H as [N [E1 [E2 E3]]]. inversion N. subst x2. 
    eapply IHn in E1. eapply IHn in E2. eapply IHn in E3.
    destruct E1 as [? [? E1]]. destruct E2 as [? [? E2]]. destruct E3 as [? [? E3]].
    eexists. split. eauto. 
    eapply ms_app1 in E1. eapply ms_app2 in E2. 
    eapply ms_trans. eapply E1.
    eapply ms_trans. eapply E2. econstructor. econstructor.
    eauto. eauto. eauto.
  - simpl in H. inversion H. eexists. split; constructor.
  - eapply tapp_inv in H. repeat destruct H as [? H].
    destruct H as [N [E1 E2]]. inversion N. subst x1. 
    eapply IHn in E1. eapply IHn in E2.
    destruct E1 as [? [? E1]]. destruct E2 as [? [? E2]]. 
    eexists. split. eauto. 
    eapply ms_tapp1 in E1. 
    eapply ms_trans. eapply E1.  econstructor. econstructor.
    eauto. 
  - simpl in H. inversion H. eexists. split; constructor.
Qed.
