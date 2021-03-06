%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
%************************************************************************
%*                                                                      *
\section[OccurAnal]{Occurrence analysis pass}
%*                                                                      *
%************************************************************************

The occurrence analyser re-typechecks a core expression, returning a new
core expression with (hopefully) improved usage information.

\begin{code}
module OccurAnal (
        occurAnalysePgm, occurAnalyseExpr
    ) where

#include "HsVersions.h"

import CoreSyn
import CoreFVs
import CoreUtils        ( exprIsTrivial, isDefaultAlt, isExpandableApp, mkCoerce )
import Id
import Name( localiseName )
import BasicTypes
import Module( Module )
import Coercion

import VarSet
import VarEnv
import Var

import Maybes           ( orElse )
import Digraph          ( SCC(..), stronglyConnCompFromEdgedVerticesR )
import PrelNames        ( buildIdKey, foldrIdKey, runSTRepIdKey, augmentIdKey )
import Unique
import UniqFM
import Util             ( mapAndUnzip, filterOut, fstOf3 )
import Bag
import Outputable
import FastString
import Data.List
\end{code}


%************************************************************************
%*                                                                      *
\subsection[OccurAnal-main]{Counting occurrences: main function}
%*                                                                      *
%************************************************************************

Here's the externally-callable interface:

\begin{code}
occurAnalysePgm :: Module	-- Used only in debug output
                -> (Activation -> Bool) 
                -> [CoreRule] -> [CoreVect]
                -> [CoreBind] -> [CoreBind]
occurAnalysePgm this_mod active_rule imp_rules vects binds
  | isEmptyVarEnv final_usage
  = binds'
  | otherwise	-- See Note [Glomming]
  = WARN( True, hang (text "Glomming in" <+> ppr this_mod <> colon)
                   2 (ppr final_usage ) )
    [Rec (flattenBinds binds')]	 
  where
    (final_usage, binds') = go (initOccEnv active_rule) binds

    initial_uds = addIdOccs emptyDetails 
                            (rulesFreeVars imp_rules `unionVarSet` vectsFreeVars vects)
    -- The RULES and VECTORISE declarations keep things alive!

    go :: OccEnv -> [CoreBind] -> (UsageDetails, [CoreBind])
    go _ []
        = (initial_uds, [])
    go env (bind:binds)
        = (final_usage, bind' ++ binds')
        where
           (bs_usage, binds')   = go env binds
           (final_usage, bind') = occAnalBind env env bind bs_usage

occurAnalyseExpr :: CoreExpr -> CoreExpr
        -- Do occurrence analysis, and discard occurence info returned
occurAnalyseExpr expr 
  = snd (occAnal (initOccEnv all_active_rules) expr)
  where
    -- To be conservative, we say that all inlines and rules are active
    all_active_rules = \_ -> True
\end{code}


%************************************************************************
%*                                                                      *
\subsection[OccurAnal-main]{Counting occurrences: main function}
%*                                                                      *
%************************************************************************

Bindings
~~~~~~~~

\begin{code}
occAnalBind :: OccEnv 		-- The incoming OccEnv
	    -> OccEnv		-- Same, but trimmed by (binderOf bind)
            -> CoreBind
            -> UsageDetails             -- Usage details of scope
            -> (UsageDetails,           -- Of the whole let(rec)
                [CoreBind])

occAnalBind env _ (NonRec binder rhs) body_usage
  | isTyVar binder	-- A type let; we don't gather usage info
  = (body_usage, [NonRec binder rhs])

  | not (binder `usedIn` body_usage)    -- It's not mentioned
  = (body_usage, [])

  | otherwise                   -- It's mentioned in the body
  = (body_usage' +++ rhs_usage3, [NonRec tagged_binder rhs'])
  where
    (body_usage', tagged_binder) = tagBinder body_usage binder
    (rhs_usage1, rhs')           = occAnalRhs env (Just tagged_binder) rhs
    rhs_usage2 = addIdOccs rhs_usage1 (idUnfoldingVars binder)
    rhs_usage3 = addIdOccs rhs_usage2 (idRuleVars binder)
       -- See Note [Rules are extra RHSs] and Note [Rule dependency info]

occAnalBind _ env (Rec pairs) body_usage
  = foldr occAnalRec (body_usage, []) sccs
	-- For a recursive group, we 
	--	* occ-analyse all the RHSs
	--	* compute strongly-connected components
	--	* feed those components to occAnalRec
  where
    bndr_set = mkVarSet (map fst pairs)

    sccs :: [SCC (Node Details)]
    sccs = {-# SCC "occAnalBind.scc" #-} stronglyConnCompFromEdgedVerticesR nodes

    nodes :: [Node Details]
    nodes = {-# SCC "occAnalBind.assoc" #-} map (makeNode env bndr_set) pairs
\end{code}

Note [Dead code]
~~~~~~~~~~~~~~~~
Dropping dead code for recursive bindings is done in a very simple way:

        the entire set of bindings is dropped if none of its binders are
        mentioned in its body; otherwise none are.

This seems to miss an obvious improvement.

        letrec  f = ...g...
                g = ...f...
        in
        ...g...
===>
        letrec f = ...g...
               g = ...(...g...)...
        in
        ...g...

Now 'f' is unused! But it's OK!  Dependency analysis will sort this
out into a letrec for 'g' and a 'let' for 'f', and then 'f' will get
dropped.  It isn't easy to do a perfect job in one blow.  Consider

        letrec f = ...g...
               g = ...h...
               h = ...k...
               k = ...m...
               m = ...m...
        in
        ...m...


------------------------------------------------------------
Note [Forming Rec groups]
~~~~~~~~~~~~~~~~~~~~~~~~~
We put bindings {f = ef; g = eg } in a Rec group if "f uses g"
and "g uses f", no matter how indirectly.  We do a SCC analysis
with an edge f -> g if "f uses g".

More precisely, "f uses g" iff g should be in scope whereever f is.
That is, g is free in:
  a) the rhs 'ef'
  b) or the RHS of a rule for f (Note [Rules are extra RHSs])
  c) or the LHS or a rule for f (Note [Rule dependency info])

These conditions apply regardless of the activation of the RULE (eg it might be
inactive in this phase but become active later).  Once a Rec is broken up
it can never be put back together, so we must be conservative.

The principle is that, regardless of rule firings, every variale is
always in scope.

  * Note [Rules are extra RHSs]
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~
    A RULE for 'f' is like an extra RHS for 'f'. That way the "parent"
    keeps the specialised "children" alive.  If the parent dies
    (because it isn't referenced any more), then the children will die
    too (unless they are already referenced directly).

    To that end, we build a Rec group for each cyclic strongly
    connected component,
        *treating f's rules as extra RHSs for 'f'*.
    More concretely, the SCC analysis runs on a graph with an edge
    from f -> g iff g is mentioned in
        (a) f's rhs
        (b) f's RULES
    These are rec_edges.

    Under (b) we include variables free in *either* LHS *or* RHS of
    the rule.  The former might seems silly, but see Note [Rule
    dependency info].  So in Example [eftInt], eftInt and eftIntFB
    will be put in the same Rec, even though their 'main' RHSs are
    both non-recursive.

  * Note [Rule dependency info]
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~
    The VarSet in a SpecInfo is used for dependency analysis in the
    occurrence analyser.  We must track free vars in *both* lhs and rhs.  
    Hence use of idRuleVars, rather than idRuleRhsVars in occAnalBind.
    Why both? Consider
        x = y
        RULE f x = v+4
    Then if we substitute y for x, we'd better do so in the
    rule's LHS too, so we'd better ensure the RULE appears to mention 'x'
    as well as 'v'

  * Note [Rules are visible in their own rec group]
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    We want the rules for 'f' to be visible in f's right-hand side.
    And we'd like them to be visible in other functions in f's Rec
    group.  E.g. in Note [Specialisation rules] we want f' rule
    to be visible in both f's RHS, and fs's RHS.

    This means that we must simplify the RULEs first, before looking
    at any of the definitions.  This is done by Simplify.simplRecBind,
    when it calls addLetIdInfo.

------------------------------------------------------------
Note [Choosing loop breakers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Loop breaking is surprisingly subtle.  First read the section 4 of
"Secrets of the GHC inliner".  This describes our basic plan.
We avoid infinite inlinings by choosing loop breakers, and
ensuring that a loop breaker cuts each loop.  

Fundamentally, we do SCC analysis on a graph.  For each recursive
group we choose a loop breaker, delete all edges to that node, 
re-analyse the SCC, and iterate.

But what is the graph?  NOT the same graph as was used for Note
[Forming Rec groups]!  In particular, a RULE is like an equation for
'f' that is *always* inlined if it is applicable.  We do *not* disable
rules for loop-breakers.  It's up to whoever makes the rules to make
sure that the rules themselves always terminate.  See Note [Rules for
recursive functions] in Simplify.lhs

Hence, if
    f's RHS (or its INLINE template if it has one) mentions g, and
    g has a RULE that mentions h, and
    h has a RULE that mentions f

then we *must* choose f to be a loop breaker.  Example: see Note
[Specialisation rules].

In general, take the free variables of f's RHS, and augment it with
all the variables reachable by RULES from those starting points.  That
is the whole reason for computing rule_fv_env in occAnalBind.  (Of
course we only consider free vars that are also binders in this Rec
group.)  See also Note [Finding rule RHS free vars]

Note that when we compute this rule_fv_env, we only consider variables
free in the *RHS* of the rule, in contrast to the way we build the
Rec group in the first place (Note [Rule dependency info])

Note that if 'g' has RHS that mentions 'w', we should add w to
g's loop-breaker edges.  More concretely there is an edge from f -> g 
iff
	(a) g is mentioned in f's RHS `xor` f's INLINE rhs 
	    (see Note [Inline rules])
	(b) or h is mentioned in f's RHS, and 
            g appears in the RHS of an active RULE of h
            or a transitive sequence of active rules starting with h
	   
Why "active rules"?  See Note [Finding rule RHS free vars]

Note that in Example [eftInt], *neither* eftInt *nor* eftIntFB is
chosen as a loop breaker, because their RHSs don't mention each other.
And indeed both can be inlined safely.

Note again that the edges of the graph we use for computing loop breakers
are not the same as the edges we use for computing the Rec blocks.
That's why we compute
    rec_edges          for the Rec block analysis
    loop_breaker_edges for the loop breaker analysis

  * Note [Finding rule RHS free vars]
    ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Consider this real example from Data Parallel Haskell
	 tagZero :: Array Int -> Array Tag
	 {-# INLINE [1] tagZeroes #-}
	 tagZero xs = pmap (\x -> fromBool (x==0)) xs

	 {-# RULES "tagZero" [~1] forall xs n.
	     pmap fromBool <blah blah> = tagZero xs #-}     
    So tagZero's RHS mentions pmap, and pmap's RULE mentions tagZero.
    However, tagZero can only be inlined in phase 1 and later, while
    the RULE is only active *before* phase 1.  So there's no problem.

    To make this work, we look for the RHS free vars only for
    *active* rules. More precisely, in the rules that are active now
    or might *become* active in a later phase.  We need the latter
    because (curently) we don't 

    That's the reason for the is_active argument
    to idRhsRuleVars, and the occ_rule_act field of the OccEnv.
 
  * Note [Weak loop breakers]
    ~~~~~~~~~~~~~~~~~~~~~~~~~
    There is a last nasty wrinkle.  Suppose we have

        Rec { f = f_rhs
              RULE f [] = g

              h = h_rhs
              g = h
              ...more...
        }

    Remember that we simplify the RULES before any RHS (see Note
    [Rules are visible in their own rec group] above).

    So we must *not* postInlineUnconditionally 'g', even though
    its RHS turns out to be trivial.  (I'm assuming that 'g' is
    not choosen as a loop breaker.)  Why not?  Because then we
    drop the binding for 'g', which leaves it out of scope in the
    RULE!
  
    Here's a somewhat different example of the same thing
        Rec { g = h
            ; h = ...f...
            ; f = f_rhs
              RULE f [] = g }
    Here the RULE is "below" g, but we *still* can't postInlineUnconditionally
    because the RULE for f is active throughout.  So the RHS of h
    might rewrite to 	 h = ...g...
    So g must remain in scope in the output program!
    
    We "solve" this by:

        Make g a "weak" loop breaker (OccInfo = IAmLoopBreaker True)
        iff g appears in the LHS or RHS of any rule for the Rec
	whether or not the rule is active
  
    A normal "strong" loop breaker has IAmLoopBreaker False.  So

                                Inline  postInlineUnconditionally
        IAmLoopBreaker False    no      no
        IAmLoopBreaker True     yes     no
        other                   yes     yes

    The **sole** reason for this kind of loop breaker is so that
    postInlineUnconditionally does not fire.  Ugh.  (Typically it'll
    inline via the usual callSiteInline stuff, so it'll be dead in the
    next pass, so the main Ugh is the tiresome complication.)

Note [Rules for imported functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this
   f = /\a. B.g a
   RULE B.g Int = 1 + f Int
Note that 
  * The RULE is for an imported function.  
  * f is non-recursive
Now we
can get
   f Int --> B.g Int	  Inlining f
         --> 1 + f Int    Firing RULE
and so the simplifier goes into an infinite loop. This 
would not happen if the RULE was for a local function,
because we keep track of dependencies through rules.  But
that is pretty much impossible to do for imported Ids.  Suppose
f's definition had been
   f = /\a. C.h a
where (by some long and devious process), C.h eventually inlines to
B.g.  We could only spot such loops by exhaustively following
unfoldings of C.h etc, in case we reach B.g, and hence (via the RULE)
f.

Note that RULES for imported functions are important in practice; they
occur a lot in the libraries.

We regard this potential infinite loop as a *programmer* error.
It's up the programmer not to write silly rules like
     RULE f x = f x
and the example above is just a more complicated version. 

Note [Specialising imported functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
BUT for *automatically-generated* rules, the programmer can't be
responsible for the "programmer error" in Note [Rules for imported
functions].  In paricular, consider specialising a recursive function
defined in another module.  If we specialise a recursive function B.g,
we get
	 g_spec = .....(B.g Int).....
	 RULE B.g Int = g_spec 
Here, g_spec doesn't look recursive, but when the rule fires, it
becomes so.  And if B.g was mutually recursive, the loop might
not be as obvious as it is here.

To avoid this, 
 * When specialising a function that is a loop breaker, 
   give a NOINLINE pragma to the specialised function

Note [Glomming]
~~~~~~~~~~~~~~~
RULES for imported Ids can make something at the top refer to something at the bottom:
	f = \x -> B.g (q x)
	h = \y -> 3
	
	RULE:  B.g (q x) = h x

Applying this rule makes f refer to h, although f doesn't appear to
depend on h.  (And, as in Note [Rules for imported functions], the
dependency might be more indirect. For example, f might mention C.t
rather than B.g, where C.t eventually inlines to B.g.)

NOTICE that this cannot happen for rules whose head is a
locally-defined function, because we accurately track dependencies
through RULES.  It only happens for rules whose head is an imported
function (B.g in the example above).

Solution:
  - When simplifying, bring all top level identifiers into
    scope at the start, ignoring the Rec/NonRec structure, so 
    that when 'h' pops up in f's rhs, we find it in the in-scope set
    (as the simplifier generally expects). This happens in simplTopBinds.

  - In the occurrence analyser, if there are any out-of-scope
    occurrences that pop out of the top, which will happen after
    firing the rule:      f = \x -> h x
                          h = \y -> 3
    then just glom all the bindings into a single Rec, so that
    the *next* iteration of the occurrence analyser will sort 
    them all out.   This part happens in occurAnalysePgm.

------------------------------------------------------------
Note [Inline rules]
~~~~~~~~~~~~~~~~~~~
None of the above stuff about RULES applies to Inline Rules,
stored in a CoreUnfolding.  The unfolding, if any, is simplified
at the same time as the regular RHS of the function (ie *not* like
Note [Rules are visible in their own rec group]), so it should be
treated *exactly* like an extra RHS.

Or, rather, when computing loop-breaker edges,
  * If f has an INLINE pragma, and it is active, we treat the
    INLINE rhs as f's rhs
  * If it's inactive, we treat f as having no rhs
  * If it has no INLINE pragma, we look at f's actual rhs


There is a danger that we'll be sub-optimal if we see this
     f = ...f...
     [INLINE f = ..no f...]
where f is recursive, but the INLINE is not. This can just about
happen with a sufficiently odd set of rules; eg

	foo :: Int -> Int
	{-# INLINE [1] foo #-}
	foo x = x+1

	bar :: Int -> Int
	{-# INLINE [1] bar #-}
	bar x = foo x + 1

	{-# RULES "foo" [~1] forall x. foo x = bar x #-}

Here the RULE makes bar recursive; but it's INLINE pragma remains
non-recursive. It's tempting to then say that 'bar' should not be
a loop breaker, but an attempt to do so goes wrong in two ways:
   a) We may get
         $df = ...$cfoo...
         $cfoo = ...$df....
         [INLINE $cfoo = ...no-$df...]
      But we want $cfoo to depend on $df explicitly so that we
      put the bindings in the right order to inline $df in $cfoo
      and perhaps break the loop altogether.  (Maybe this
   b)


Example [eftInt]
~~~~~~~~~~~~~~~
Example (from GHC.Enum):

  eftInt :: Int# -> Int# -> [Int]
  eftInt x y = ...(non-recursive)...

  {-# INLINE [0] eftIntFB #-}
  eftIntFB :: (Int -> r -> r) -> r -> Int# -> Int# -> r
  eftIntFB c n x y = ...(non-recursive)...

  {-# RULES
  "eftInt"  [~1] forall x y. eftInt x y = build (\ c n -> eftIntFB c n x y)
  "eftIntList"  [1] eftIntFB  (:) [] = eftInt
   #-}

Note [Specialisation rules]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this group, which is typical of what SpecConstr builds:

   fs a = ....f (C a)....
   f  x = ....f (C a)....
   {-# RULE f (C a) = fs a #-}

So 'f' and 'fs' are in the same Rec group (since f refers to fs via its RULE).

But watch out!  If 'fs' is not chosen as a loop breaker, we may get an infinite loop:
  - the RULE is applied in f's RHS (see Note [Self-recursive rules] in Simplify
  - fs is inlined (say it's small)
  - now there's another opportunity to apply the RULE

This showed up when compiling Control.Concurrent.Chan.getChanContents.


\begin{code}
type Node details = (details, Unique, [Unique])	-- The Ints are gotten from the Unique,
						-- which is gotten from the Id.
data Details
  = ND { nd_bndr :: Id          -- Binder
       , nd_rhs  :: CoreExpr    -- RHS, already occ-analysed

       , nd_uds  :: UsageDetails  -- Usage from RHS, and RULES, and InlineRule unfolding
       	 	    		  -- ignoring phase (ie assuming all are active)
				  -- See Note [Forming Rec groups]

       , nd_inl  :: IdSet       -- Free variables of
                                --   the InlineRule (if present and active)
                                --   or the RHS (ir no InlineRule)
                                -- but excluding any RULES
                                -- This is the IdSet that may be used if the Id is inlined

       , nd_rule_fvs :: IdSet          -- Free variables of LHS or RHS of all RULES
       	 	     		       --      whether active or not
       , nd_active_rule_fvs :: IdSet   -- Free variables of the RHS of active RULES

       -- In the last two fields, we haev already expanded occurrences
       -- of imported Ids for which we have local RULES, to their local-id sets
  }

makeNode :: OccEnv -> VarSet -> (Var, CoreExpr) -> Node Details
makeNode env bndr_set (bndr, rhs)
  = (details, varUnique bndr, keysUFM (udFreeVars bndr_set rhs_usage3))
  where
    details = ND { nd_bndr = bndr
                 , nd_rhs  = rhs'
                 , nd_uds  = rhs_usage3
                 , nd_inl  = inl_fvs
		 , nd_rule_fvs = all_rule_fvs
                 , nd_active_rule_fvs = active_rule_fvs }

    -- Constructing the edges for the main Rec computation
    -- See Note [Forming Rec groups]
    (rhs_usage1, rhs') = occAnalRhs env Nothing rhs
    rhs_usage2 = addIdOccs rhs_usage1 all_rule_fvs   -- Note [Rules are extra RHSs]
                                                     -- Note [Rule dependency info]
    rhs_usage3 = case mb_unf_fvs of
                   Just unf_fvs -> addIdOccs rhs_usage2 unf_fvs
                   Nothing      -> rhs_usage2

    -- Finding the free variables of the rules
    is_active = occ_rule_act env :: Activation -> Bool
    rules = filterOut isBuiltinRule (idCoreRules bndr)
    rules_w_fvs :: [(Activation, VarSet)]    -- Find the RHS fvs
    rules_w_fvs = [ (ru_act rule, fvs)
                  | rule <- rules
                  , let fvs = exprFreeVars (ru_rhs rule)
		    	      `delVarSetList` ru_bndrs rule
                  , not (isEmptyVarSet fvs) ]
    all_rule_fvs = foldr (unionVarSet . snd) rule_lhs_fvs rules_w_fvs
    rule_lhs_fvs = foldr (unionVarSet . (\ru -> exprsFreeVars (ru_args ru)
                                                `delVarSetList` ru_bndrs ru))
                         emptyVarSet rules
    active_rule_fvs = unionVarSets [fvs | (a,fvs) <- rules_w_fvs, is_active a]

    -- Finding the free variables of the INLINE pragma (if any)
    unf        = realIdUnfolding bndr     -- Ignore any current loop-breaker flag
    mb_unf_fvs = stableUnfoldingVars isLocalId unf

    -- Find the "nd_inl" free vars; for the loop-breaker phase
    inl_fvs = case mb_unf_fvs of
                Nothing	-> udFreeVars bndr_set rhs_usage1 -- No INLINE, use RHS
                Just unf_fvs -> unf_fvs	
                      -- We could check for an *active* INLINE (returning
		      -- emptyVarSet for an inactive one), but is_active
		      -- isn't the right thing (it tells about
		      -- RULE activation), so we'd need more plumbing

-----------------------------
occAnalRec :: SCC (Node Details)
           -> (UsageDetails, [CoreBind])
	   -> (UsageDetails, [CoreBind])

	-- The NonRec case is just like a Let (NonRec ...) above
occAnalRec (AcyclicSCC (ND { nd_bndr = bndr, nd_rhs = rhs, nd_uds = rhs_uds}, _, _))
           (body_uds, binds)
  | not (bndr `usedIn` body_uds) 
  = (body_uds, binds)

  | otherwise			-- It's mentioned in the body
  = (body_uds' +++ rhs_uds,	
     NonRec tagged_bndr rhs : binds)
  where
    (body_uds', tagged_bndr) = tagBinder body_uds bndr

	-- The Rec case is the interesting one
	-- See Note [Loop breaking]
occAnalRec (CyclicSCC nodes) (body_uds, binds)
  | not (any (`usedIn` body_uds) bndrs)	-- NB: look at body_uds, not total_uds
  = (body_uds, binds)				-- Dead code

  | otherwise	-- At this point we always build a single Rec
  = (final_uds, Rec pairs : binds)

  where
    bndrs    = [b | (ND { nd_bndr = b }, _, _) <- nodes]
    bndr_set = mkVarSet bndrs

	----------------------------
	-- Tag the binders with their occurrence info
    tagged_nodes = map tag_node nodes
    total_uds = foldl add_uds body_uds nodes
    final_uds = total_uds `minusVarEnv` bndr_set
    add_uds usage_so_far (nd, _, _) = usage_so_far +++ nd_uds nd

    tag_node :: Node Details -> Node Details
    tag_node (details@ND { nd_bndr = bndr }, k, ks)
      = (details { nd_bndr = setBinderOcc total_uds bndr }, k, ks)

    ---------------------------
    -- Now reconstruct the cycle
    pairs :: [(Id,CoreExpr)]
    pairs | any non_boring bndrs = loopBreakNodes 0 bndr_set rule_fvs loop_breaker_edges []
          | otherwise            = reOrderNodes   0 bndr_set rule_fvs tagged_nodes       []
    non_boring bndr = isId bndr &&
                      (isStableUnfolding (realIdUnfolding bndr) || idHasRules bndr)
		      -- If all are boring, the loop_breaker_edges will be a single Cyclic SCC

	-- See Note [Choosing loop breakers] for loop_breaker_edges
    loop_breaker_edges = map mk_node tagged_nodes
    mk_node (details@(ND { nd_inl = inl_fvs }), k, _) 
      = (details, k, keysUFM (extendFvs_ rule_fv_env inl_fvs))

    ------------------------------------
    rule_fvs :: VarSet
    rule_fvs = foldr (unionVarSet . nd_rule_fvs . fstOf3) emptyVarSet nodes

    rule_fv_env :: IdEnv IdSet  
        -- Maps a variable f to the variables from this group 
        --      mentioned in RHS of active rules for f
        -- Domain is *subset* of bound vars (others have no rule fvs)
    rule_fv_env = transClosureFV (mkVarEnv init_rule_fvs)
    init_rule_fvs   -- See Note [Finding rule RHS free vars]
      = [ (b, trimmed_rule_fvs)
        | (ND { nd_bndr = b, nd_active_rule_fvs = rule_fvs },_,_) <- nodes
        , let trimmed_rule_fvs = rule_fvs `intersectVarSet` bndr_set
        , not (isEmptyVarSet trimmed_rule_fvs)]
\end{code}

@loopBreakSCC@ is applied to the list of (binder,rhs) pairs for a cyclic
strongly connected component (there's guaranteed to be a cycle).  It returns the
same pairs, but
        a) in a better order,
        b) with some of the Ids having a IAmALoopBreaker pragma

The "loop-breaker" Ids are sufficient to break all cycles in the SCC.  This means
that the simplifier can guarantee not to loop provided it never records an inlining
for these no-inline guys.

Furthermore, the order of the binds is such that if we neglect dependencies
on the no-inline Ids then the binds are topologically sorted.  This means
that the simplifier will generally do a good job if it works from top bottom,
recording inlinings for any Ids which aren't marked as "no-inline" as it goes.

\begin{code}
type Binding = (Id,CoreExpr)

mk_loop_breaker :: Node Details -> Binding
mk_loop_breaker (ND { nd_bndr = bndr, nd_rhs = rhs}, _, _) 
  = (setIdOccInfo bndr strongLoopBreaker, rhs)

mk_non_loop_breaker :: VarSet -> Node Details -> Binding
-- See Note [Weak loop breakers]
mk_non_loop_breaker used_in_rules (ND { nd_bndr = bndr, nd_rhs = rhs}, _, _) 
  | bndr `elemVarSet` used_in_rules = (setIdOccInfo bndr weakLoopBreaker, rhs)
  | otherwise                       = (bndr, rhs)

udFreeVars :: VarSet -> UsageDetails -> VarSet
-- Find the subset of bndrs that are mentioned in uds
udFreeVars bndrs uds = intersectUFM_C (\b _ -> b) bndrs uds

loopBreakNodes :: Int 
	       -> VarSet -> VarSet	-- All binders, and binders used in RULES
               -> [Node Details]
               -> [Binding]	        -- Append these to the end
               -> [Binding]
-- Return the bindings sorted into a plausible order, and marked with loop breakers.  
loopBreakNodes depth bndr_set used_in_rules nodes binds
  = go (stronglyConnCompFromEdgedVerticesR nodes) binds
  where
    go []         binds = binds
    go (scc:sccs) binds = loop_break_scc scc (go sccs binds)

    loop_break_scc scc binds
      = case scc of
          AcyclicSCC node  -> mk_non_loop_breaker used_in_rules node : binds
          CyclicSCC [node] -> mk_loop_breaker node : binds
          CyclicSCC nodes  -> reOrderNodes depth bndr_set used_in_rules nodes binds

reOrderNodes :: Int -> VarSet -> VarSet -> [Node Details] -> [Binding] -> [Binding]
    -- Choose a loop breaker, mark it no-inline,
    -- do SCC analysis on the rest, and recursively sort them out
reOrderNodes _ _ _ [] _  = panic "reOrderNodes"
reOrderNodes depth bndr_set used_in_rules (node : nodes) binds
  = loopBreakNodes new_depth bndr_set used_in_rules unchosen $
    (map mk_loop_breaker chosen_nodes ++ binds)
  where
    (chosen_nodes, unchosen) = choose_loop_breaker (score node) [node] [] nodes

    approximate_loop_breaker = depth >= 2
    new_depth | approximate_loop_breaker = 0
	      | otherwise		 = depth+1
	-- After two iterations (d=0, d=1) give up
	-- and approximate, returning to d=0

    choose_loop_breaker :: Int			-- Best score so far
                        -> [Node Details]	-- Nodes with this score
                        -> [Node Details] 	-- Nodes with higher scores
                        -> [Node Details]	-- Unprocessed nodes
                        -> ([Node Details], [Node Details])
        -- This loop looks for the bind with the lowest score
        -- to pick as the loop  breaker.  The rest accumulate in
    choose_loop_breaker _ loop_nodes acc []
        = (loop_nodes, acc)        -- Done

	-- If approximate_loop_breaker is True, we pick *all*
	-- nodes with lowest score, else just one
	-- See Note [Complexity of loop breaking]
    choose_loop_breaker loop_sc loop_nodes acc (node : nodes)
        | sc < loop_sc  -- Lower score so pick this new one
        = choose_loop_breaker sc [node] (loop_nodes ++ acc) nodes

	| approximate_loop_breaker && sc == loop_sc
	= choose_loop_breaker loop_sc (node : loop_nodes) acc nodes
	
        | otherwise     -- Higher score so don't pick it
        = choose_loop_breaker loop_sc loop_nodes (node : acc) nodes
        where
          sc = score node

    score :: Node Details -> Int        -- Higher score => less likely to be picked as loop breaker
    score (ND { nd_bndr = bndr, nd_rhs = rhs }, _, _)
        | not (isId bndr) = 100	    -- A type or cercion variable is never a loop breaker

        | isDFunId bndr = 9   -- Never choose a DFun as a loop breaker
	   	     	      -- Note [DFuns should not be loop breakers]

        | Just inl_source <- isStableCoreUnfolding_maybe (idUnfolding bndr)
	= case inl_source of
	     InlineWrapper {} -> 10  -- Note [INLINE pragmas]
	     _other	      ->  3  -- Data structures are more important than this
	     		             -- so that dictionary/method recursion unravels
		-- Note that this case hits all InlineRule things, so we
		-- never look at 'rhs' for InlineRule stuff. That's right, because
		-- 'rhs' is irrelevant for inlining things with an InlineRule
                
        | is_con_app rhs = 5  -- Data types help with cases: Note [Constructor applications]
                
        | exprIsTrivial rhs = 10  -- Practically certain to be inlined
                -- Used to have also: && not (isExportedId bndr)
                -- But I found this sometimes cost an extra iteration when we have
                --      rec { d = (a,b); a = ...df...; b = ...df...; df = d }
                -- where df is the exported dictionary. Then df makes a really
                -- bad choice for loop breaker

	
-- If an Id is marked "never inline" then it makes a great loop breaker
-- The only reason for not checking that here is that it is rare
-- and I've never seen a situation where it makes a difference,
-- so it probably isn't worth the time to test on every binder
--	| isNeverActive (idInlinePragma bndr) = -10

        | isOneOcc (idOccInfo bndr) = 2  -- Likely to be inlined

        | canUnfold (realIdUnfolding bndr) = 1
                -- The Id has some kind of unfolding
		-- Ignore loop-breaker-ness here because that is what we are setting!

        | otherwise = 0

	-- Checking for a constructor application
        -- Cheap and cheerful; the simplifer moves casts out of the way
        -- The lambda case is important to spot x = /\a. C (f a)
        -- which comes up when C is a dictionary constructor and
        -- f is a default method.
        -- Example: the instance for Show (ST s a) in GHC.ST
        --
        -- However we *also* treat (\x. C p q) as a con-app-like thing,
        --      Note [Closure conversion]
    is_con_app (Var v)    = isConLikeId v
    is_con_app (App f _)  = is_con_app f
    is_con_app (Lam _ e)  = is_con_app e
    is_con_app (Note _ e) = is_con_app e
    is_con_app _          = False
\end{code}

Note [Complexity of loop breaking]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The loop-breaking algorithm knocks out one binder at a time, and 
performs a new SCC analysis on the remaining binders.  That can
behave very badly in tightly-coupled groups of bindings; in the
worst case it can be (N**2)*log N, because it does a full SCC
on N, then N-1, then N-2 and so on.

To avoid this, we switch plans after 2 (or whatever) attempts:
  Plan A: pick one binder with the lowest score, make it
	  a loop breaker, and try again
  Plan B: pick *all* binders with the lowest score, make them
	  all loop breakers, and try again 
Since there are only a small finite number of scores, this will
terminate in a constant number of iterations, rather than O(N)
iterations.

You might thing that it's very unlikely, but RULES make it much
more likely.  Here's a real example from Trac #1969:
  Rec { $dm = \d.\x. op d
	{-# RULES forall d. $dm Int d  = $s$dm1
		  forall d. $dm Bool d = $s$dm2 #-}
	
	dInt = MkD .... opInt ...
	dInt = MkD .... opBool ...
	opInt  = $dm dInt
	opBool = $dm dBool

	$s$dm1 = \x. op dInt
	$s$dm2 = \x. op dBool }
The RULES stuff means that we can't choose $dm as a loop breaker
(Note [Choosing loop breakers]), so we must choose at least (say)
opInt *and* opBool, and so on.  The number of loop breakders is
linear in the number of instance declarations.

Note [INLINE pragmas]
~~~~~~~~~~~~~~~~~~~~~
Avoid choosing a function with an INLINE pramga as the loop breaker!  
If such a function is mutually-recursive with a non-INLINE thing,
then the latter should be the loop-breaker.

Usually this is just a question of optimisation. But a particularly
bad case is wrappers generated by the demand analyser: if you make
then into a loop breaker you may get an infinite inlining loop.  For
example:
  rec {
        $wfoo x = ....foo x....

        {-loop brk-} foo x = ...$wfoo x...
  }
The interface file sees the unfolding for $wfoo, and sees that foo is
strict (and hence it gets an auto-generated wrapper).  Result: an
infinite inlining in the importing scope.  So be a bit careful if you
change this.  A good example is Tree.repTree in
nofib/spectral/minimax. If the repTree wrapper is chosen as the loop
breaker then compiling Game.hs goes into an infinite loop.  This
happened when we gave is_con_app a lower score than inline candidates:

  Tree.repTree
    = __inline_me (/\a. \w w1 w2 -> 
                   case Tree.$wrepTree @ a w w1 w2 of
                    { (# ww1, ww2 #) -> Branch @ a ww1 ww2 })
  Tree.$wrepTree
    = /\a w w1 w2 -> 
      (# w2_smP, map a (Tree a) (Tree.repTree a w1 w) (w w2) #)

Here we do *not* want to choose 'repTree' as the loop breaker.

Note [DFuns should not be loop breakers]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's particularly bad to make a DFun into a loop breaker.  See
Note [How instance declarations are translated] in TcInstDcls

We give DFuns a higher score than ordinary CONLIKE things because 
if there's a choice we want the DFun to be the non-looop breker. Eg
 
rec { sc = /\ a \$dC. $fBWrap (T a) ($fCT @ a $dC)

      $fCT :: forall a_afE. (Roman.C a_afE) => Roman.C (Roman.T a_afE)
      {-# DFUN #-}
      $fCT = /\a \$dC. MkD (T a) ((sc @ a $dC) |> blah) ($ctoF @ a $dC)
    }

Here 'sc' (the superclass) looks CONLIKE, but we'll never get to it
if we can't unravel the DFun first.

Note [Constructor applications]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's really really important to inline dictionaries.  Real
example (the Enum Ordering instance from GHC.Base):

     rec     f = \ x -> case d of (p,q,r) -> p x
             g = \ x -> case d of (p,q,r) -> q x
             d = (v, f, g)

Here, f and g occur just once; but we can't inline them into d.
On the other hand we *could* simplify those case expressions if
we didn't stupidly choose d as the loop breaker.
But we won't because constructor args are marked "Many".
Inlining dictionaries is really essential to unravelling
the loops in static numeric dictionaries, see GHC.Float.

Note [Closure conversion]
~~~~~~~~~~~~~~~~~~~~~~~~~
We treat (\x. C p q) as a high-score candidate in the letrec scoring algorithm.
The immediate motivation came from the result of a closure-conversion transformation
which generated code like this:

    data Clo a b = forall c. Clo (c -> a -> b) c

    ($:) :: Clo a b -> a -> b
    Clo f env $: x = f env x

    rec { plus = Clo plus1 ()

        ; plus1 _ n = Clo plus2 n

        ; plus2 Zero     n = n
        ; plus2 (Succ m) n = Succ (plus $: m $: n) }

If we inline 'plus' and 'plus1', everything unravels nicely.  But if
we choose 'plus1' as the loop breaker (which is entirely possible
otherwise), the loop does not unravel nicely.


@occAnalRhs@ deals with the question of bindings where the Id is marked
by an INLINE pragma.  For these we record that anything which occurs
in its RHS occurs many times.  This pessimistically assumes that ths
inlined binder also occurs many times in its scope, but if it doesn't
we'll catch it next time round.  At worst this costs an extra simplifier pass.
ToDo: try using the occurrence info for the inline'd binder.

[March 97] We do the same for atomic RHSs.  Reason: see notes with loopBreakSCC.
[June 98, SLPJ]  I've undone this change; I don't understand it.  See notes with loopBreakSCC.


\begin{code}
occAnalRhs :: OccEnv
           -> Maybe Id -> CoreExpr    -- Binder and rhs
                 -- Just b  => non-rec, and alrady tagged with occurrence info
                 -- Nothing => Rec, no occ info
           -> (UsageDetails, CoreExpr)
              -- Returned usage details covers only the RHS,
              -- and *not* the RULE or INLINE template for the Id
occAnalRhs env mb_bndr rhs
  = occAnal ctxt rhs
  where
    -- See Note [Cascading inlines]
    ctxt = case mb_bndr of
             Just b | certainly_inline b -> env
             _other                      -> rhsCtxt env

    certainly_inline bndr  -- See Note [Cascading inlines]
      = case idOccInfo bndr of
          OneOcc in_lam one_br _ -> not in_lam && one_br && active && not_stable
          _                      -> False
      where
        active     = isAlwaysActive (idInlineActivation bndr)
        not_stable = not (isStableUnfolding (idUnfolding bndr))

addIdOccs :: UsageDetails -> VarSet -> UsageDetails
addIdOccs usage id_set = foldVarSet add usage id_set
  where
    add v u | isId v    = addOneOcc u v NoOccInfo
            | otherwise = u
	-- Give a non-committal binder info (i.e NoOccInfo) because
	--   a) Many copies of the specialised thing can appear
	--   b) We don't want to substitute a BIG expression inside a RULE
	--	even if that's the only occurrence of the thing
	--	(Same goes for INLINE.)
\end{code}

Note [Cascading inlines]
~~~~~~~~~~~~~~~~~~~~~~~~
By default we use an rhsCtxt for the RHS of a binding.  This tells the
occ anal n that it's looking at an RHS, which has an effect in
occAnalApp.  In particular, for constructor applications, it makes
the arguments appear to have NoOccInfo, so that we don't inline into
them. Thus    x = f y
              k = Just x
we do not want to inline x.

But there's a problem.  Consider
     x1 = a0 : []
     x2 = a1 : x1
     x3 = a2 : x2
     g  = f x3
First time round, it looks as if x1 and x2 occur as an arg of a
let-bound constructor ==> give them a many-occurrence.
But then x3 is inlined (unconditionally as it happens) and
next time round, x2 will be, and the next time round x1 will be
Result: multiple simplifier iterations.  Sigh.

So, when analysing the RHS of x3 we notice that x3 will itself
definitely inline the next time round, and so we analyse x3's rhs in
an ordinary context, not rhsCtxt.  Hence the "certainly_inline" stuff.

Annoyingly, we have to approximiate SimplUtils.preInlineUnconditionally.
If we say "yes" when preInlineUnconditionally says "no" the simplifier iterates
indefinitely:
        x = f y
        k = Just x
inline ==>
        k = Just (f y)
float ==>
        x1 = f y
        k = Just x1

This is worse than the slow cascade, so we only want to say "certainly_inline"
if it really is certain.  Look at the note with preInlineUnconditionally
for the various clauses.

Expressions
~~~~~~~~~~~
\begin{code}
occAnal :: OccEnv
        -> CoreExpr
        -> (UsageDetails,       -- Gives info only about the "interesting" Ids
            CoreExpr)

occAnal _   expr@(Type _) = (emptyDetails, 	   expr)
occAnal _   expr@(Lit _)  = (emptyDetails, 	   expr)   
occAnal env expr@(Var v)  = (mkOneOcc env v False, expr)
    -- At one stage, I gathered the idRuleVars for v here too,
    -- which in a way is the right thing to do.
    -- But that went wrong right after specialisation, when
    -- the *occurrences* of the overloaded function didn't have any
    -- rules in them, so the *specialised* versions looked as if they
    -- weren't used at all.

occAnal _ (Coercion co) 
  = (addIdOccs emptyDetails (coVarsOfCo co), Coercion co)
	-- See Note [Gather occurrences of coercion veriables]
\end{code}

Note [Gather occurrences of coercion veriables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We need to gather info about what coercion variables appear, so that
we can sort them into the right place when doing dependency analysis.

\begin{code}
\end{code}

\begin{code}
occAnal env (Note note@(SCC _) body)
  = case occAnal env body of { (usage, body') ->
    (mapVarEnv markInsideSCC usage, Note note body')
    }

occAnal env (Note note body)
  = case occAnal env body of { (usage, body') ->
    (usage, Note note body')
    }

occAnal env (Cast expr co)
  = case occAnal env expr of { (usage, expr') ->
    let usage1 = markManyIf (isRhsEnv env) usage
        usage2 = addIdOccs usage1 (coVarsOfCo co)
          -- See Note [Gather occurrences of coercion veriables]
    in (usage2, Cast expr' co)
        -- If we see let x = y `cast` co
        -- then mark y as 'Many' so that we don't
        -- immediately inline y again.
    }
\end{code}

\begin{code}
occAnal env app@(App _ _)
  = occAnalApp env (collectArgs app)

-- Ignore type variables altogether
--   (a) occurrences inside type lambdas only not marked as InsideLam
--   (b) type variables not in environment

occAnal env (Lam x body) | isTyVar x
  = case occAnal env body of { (body_usage, body') ->
    (body_usage, Lam x body')
    }

-- For value lambdas we do a special hack.  Consider
--      (\x. \y. ...x...)
-- If we did nothing, x is used inside the \y, so would be marked
-- as dangerous to dup.  But in the common case where the abstraction
-- is applied to two arguments this is over-pessimistic.
-- So instead, we just mark each binder with its occurrence
-- info in the *body* of the multiple lambda.
-- Then, the simplifier is careful when partially applying lambdas.

occAnal env expr@(Lam _ _)
  = case occAnal env_body body of { (body_usage, body') ->
    let
        (final_usage, tagged_binders) = tagLamBinders body_usage binders'
		      -- Use binders' to put one-shot info on the lambdas

        --      URGH!  Sept 99: we don't seem to be able to use binders' here, because
        --      we get linear-typed things in the resulting program that we can't handle yet.
        --      (e.g. PrelShow)  TODO

        really_final_usage = if linear then
                                final_usage
                             else
                                mapVarEnv markInsideLam final_usage
    in
    (really_final_usage,
     mkLams tagged_binders body') }
  where
    env_body        = vanillaCtxt (trimOccEnv env binders)
		        -- Body is (no longer) an RhsContext
    (binders, body) = collectBinders expr
    binders'        = oneShotGroup env binders
    linear          = all is_one_shot binders'
    is_one_shot b   = isId b && isOneShotBndr b

occAnal env (Case scrut bndr ty alts)
  = case occ_anal_scrut scrut alts     of { (scrut_usage, scrut') ->
    case mapAndUnzip occ_anal_alt alts of { (alts_usage_s, alts')   ->
    let
        alts_usage  = foldr1 combineAltsUsageDetails alts_usage_s
        (alts_usage1, tagged_bndr) = tag_case_bndr alts_usage bndr
        total_usage = scrut_usage +++ alts_usage1
    in
    total_usage `seq` (total_usage, Case scrut' tagged_bndr ty alts') }}
  where
	-- Note [Case binder usage]	
	-- ~~~~~~~~~~~~~~~~~~~~~~~~
        -- The case binder gets a usage of either "many" or "dead", never "one".
        -- Reason: we like to inline single occurrences, to eliminate a binding,
        -- but inlining a case binder *doesn't* eliminate a binding.
        -- We *don't* want to transform
        --      case x of w { (p,q) -> f w }
        -- into
        --      case x of w { (p,q) -> f (p,q) }
    tag_case_bndr usage bndr
      = case lookupVarEnv usage bndr of
          Nothing -> (usage,                  setIdOccInfo bndr IAmDead)
          Just _  -> (usage `delVarEnv` bndr, setIdOccInfo bndr NoOccInfo)

    alt_env      = mkAltEnv env scrut bndr
    occ_anal_alt = occAnalAlt alt_env bndr

    occ_anal_scrut (Var v) (alt1 : other_alts)
        | not (null other_alts) || not (isDefaultAlt alt1)
        = (mkOneOcc env v True, Var v)	-- The 'True' says that the variable occurs
					-- in an interesting context; the case has
					-- at least one non-default alternative
    occ_anal_scrut scrut _alts  
	= occAnal (vanillaCtxt env) scrut    -- No need for rhsCtxt

occAnal env (Let bind body)
  = case occAnal env_body body                    of { (body_usage, body') ->
    case occAnalBind env env_body bind body_usage of { (final_usage, new_binds) ->
       (final_usage, mkLets new_binds body') }}
  where
    env_body = trimOccEnv env (bindersOf bind)

occAnalArgs :: OccEnv -> [CoreExpr] -> (UsageDetails, [CoreExpr])
occAnalArgs env args
  = case mapAndUnzip (occAnal arg_env) args of  { (arg_uds_s, args') ->
    (foldr (+++) emptyDetails arg_uds_s, args')}
  where
    arg_env = vanillaCtxt env
\end{code}

Applications are dealt with specially because we want
the "build hack" to work.

Note [Arguments of let-bound constructors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
    f x = let y = expensive x in
          let z = (True,y) in
          (case z of {(p,q)->q}, case z of {(p,q)->q})
We feel free to duplicate the WHNF (True,y), but that means
that y may be duplicated thereby.

If we aren't careful we duplicate the (expensive x) call!
Constructors are rather like lambdas in this way.

\begin{code}
occAnalApp :: OccEnv
           -> (Expr CoreBndr, [Arg CoreBndr])
           -> (UsageDetails, Expr CoreBndr)
occAnalApp env (Var fun, args)
  = case args_stuff of { (args_uds, args') ->
    let
       final_args_uds = markManyIf (isRhsEnv env && is_exp) args_uds
	  -- We mark the free vars of the argument of a constructor or PAP
	  -- as "many", if it is the RHS of a let(rec).
	  -- This means that nothing gets inlined into a constructor argument
	  -- position, which is what we want.  Typically those constructor
	  -- arguments are just variables, or trivial expressions.
	  --
	  -- This is the *whole point* of the isRhsEnv predicate
	  -- See Note [Arguments of let-bound constructors]
    in
    (fun_uds +++ final_args_uds, mkApps (Var fun) args') }
  where
    fun_uniq = idUnique fun
    fun_uds  = mkOneOcc env fun (valArgCount args > 0)
    is_exp = isExpandableApp fun (valArgCount args)
    	   -- See Note [CONLIKE pragma] in BasicTypes
	   -- The definition of is_exp should match that in
	   -- Simplify.prepareRhs

                -- Hack for build, fold, runST
    args_stuff  | fun_uniq == buildIdKey    = appSpecial env 2 [True,True]  args
                | fun_uniq == augmentIdKey  = appSpecial env 2 [True,True]  args
                | fun_uniq == foldrIdKey    = appSpecial env 3 [False,True] args
                | fun_uniq == runSTRepIdKey = appSpecial env 2 [True]       args
                        -- (foldr k z xs) may call k many times, but it never
                        -- shares a partial application of k; hence [False,True]
                        -- This means we can optimise
                        --      foldr (\x -> let v = ...x... in \y -> ...v...) z xs
                        -- by floating in the v

                | otherwise = occAnalArgs env args


occAnalApp env (fun, args)
  = case occAnal (addAppCtxt env args) fun of   { (fun_uds, fun') ->
        -- The addAppCtxt is a bit cunning.  One iteration of the simplifier
        -- often leaves behind beta redexs like
        --      (\x y -> e) a1 a2
        -- Here we would like to mark x,y as one-shot, and treat the whole
        -- thing much like a let.  We do this by pushing some True items
        -- onto the context stack.

    case occAnalArgs env args of        { (args_uds, args') ->
    let
        final_uds = fun_uds +++ args_uds
    in
    (final_uds, mkApps fun' args') }}


markManyIf :: Bool              -- If this is true
           -> UsageDetails      -- Then do markMany on this
           -> UsageDetails
markManyIf True  uds = mapVarEnv markMany uds
markManyIf False uds = uds

appSpecial :: OccEnv
           -> Int -> CtxtTy     -- Argument number, and context to use for it
           -> [CoreExpr]
           -> (UsageDetails, [CoreExpr])
appSpecial env n ctxt args
  = go n args
  where
    arg_env = vanillaCtxt env

    go _ [] = (emptyDetails, [])        -- Too few args

    go 1 (arg:args)                     -- The magic arg
      = case occAnal (setCtxtTy arg_env ctxt) arg of    { (arg_uds, arg') ->
        case occAnalArgs env args of                    { (args_uds, args') ->
        (arg_uds +++ args_uds, arg':args') }}

    go n (arg:args)
      = case occAnal arg_env arg of     { (arg_uds, arg') ->
        case go (n-1) args of           { (args_uds, args') ->
        (arg_uds +++ args_uds, arg':args') }}
\end{code}


Note [Binders in case alternatives]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
    case x of y { (a,b) -> f y }
We treat 'a', 'b' as dead, because they don't physically occur in the
case alternative.  (Indeed, a variable is dead iff it doesn't occur in
its scope in the output of OccAnal.)  It really helps to know when
binders are unused.  See esp the call to isDeadBinder in
Simplify.mkDupableAlt

In this example, though, the Simplifier will bring 'a' and 'b' back to
life, beause it binds 'y' to (a,b) (imagine got inlined and
scrutinised y).

\begin{code}
occAnalAlt :: OccEnv
           -> CoreBndr
           -> CoreAlt
           -> (UsageDetails, Alt IdWithOccInfo)
occAnalAlt env case_bndr (con, bndrs, rhs)
  = let 
        env' = trimOccEnv env bndrs
    in 
    case occAnal env' rhs of { (rhs_usage1, rhs1) ->
    let
	proxies = getProxies env' case_bndr 
	(rhs_usage2, rhs2) = foldrBag wrapProxy (rhs_usage1, rhs1) proxies
        (alt_usg, tagged_bndrs) = tagLamBinders rhs_usage2 bndrs
        bndrs' = tagged_bndrs      -- See Note [Binders in case alternatives]
    in
    (alt_usg, (con, bndrs', rhs2)) }

wrapProxy :: ProxyBind -> (UsageDetails, CoreExpr) -> (UsageDetails, CoreExpr)
wrapProxy (bndr, rhs_var, co) (body_usg, body)
  | not (bndr `usedIn` body_usg) 
  = (body_usg, body)
  | otherwise
  = (body_usg' +++ rhs_usg, Let (NonRec tagged_bndr rhs) body)
  where
    (body_usg', tagged_bndr) = tagBinder body_usg bndr
    rhs_usg = unitVarEnv rhs_var NoOccInfo	-- We don't need exact info
    rhs = mkCoerce co (Var (zapIdOccInfo rhs_var)) -- See Note [Zap case binders in proxy bindings]
\end{code}


%************************************************************************
%*                                                                      *
                    OccEnv									
%*                                                                      *
%************************************************************************

\begin{code}
data OccEnv
  = OccEnv { occ_encl  	  :: !OccEncl      -- Enclosing context information
    	   , occ_ctxt  	  :: !CtxtTy       -- Tells about linearity
	   , occ_proxy 	  :: ProxyEnv
           , occ_rule_act :: Activation -> Bool   -- Which rules are active
             -- See Note [Finding rule RHS free vars]
    }

-----------------------------
-- OccEncl is used to control whether to inline into constructor arguments
-- For example:
--      x = (p,q)               -- Don't inline p or q
--      y = /\a -> (p a, q a)   -- Still don't inline p or q
--      z = f (p,q)             -- Do inline p,q; it may make a rule fire
-- So OccEncl tells enought about the context to know what to do when
-- we encounter a contructor application or PAP.

data OccEncl
  = OccRhs              -- RHS of let(rec), albeit perhaps inside a type lambda
                        -- Don't inline into constructor args here
  | OccVanilla          -- Argument of function, body of lambda, scruintee of case etc.
                        -- Do inline into constructor args here

instance Outputable OccEncl where
  ppr OccRhs     = ptext (sLit "occRhs")
  ppr OccVanilla = ptext (sLit "occVanilla")

type CtxtTy = [Bool]
        -- []           No info
        --
        -- True:ctxt    Analysing a function-valued expression that will be
        --                      applied just once
        --
        -- False:ctxt   Analysing a function-valued expression that may
        --                      be applied many times; but when it is,
        --                      the CtxtTy inside applies

initOccEnv :: (Activation -> Bool) -> OccEnv
initOccEnv active_rule 
  = OccEnv { occ_encl  = OccVanilla
	   , occ_ctxt  = []
	   , occ_proxy = PE emptyVarEnv emptyVarSet
           , occ_rule_act = active_rule }

vanillaCtxt :: OccEnv -> OccEnv
vanillaCtxt env = env { occ_encl = OccVanilla, occ_ctxt = [] }

rhsCtxt :: OccEnv -> OccEnv
rhsCtxt env = env { occ_encl = OccRhs, occ_ctxt = [] }

setCtxtTy :: OccEnv -> CtxtTy -> OccEnv
setCtxtTy env ctxt = env { occ_ctxt = ctxt }

isRhsEnv :: OccEnv -> Bool
isRhsEnv (OccEnv { occ_encl = OccRhs })     = True
isRhsEnv (OccEnv { occ_encl = OccVanilla }) = False

oneShotGroup :: OccEnv -> [CoreBndr] -> [CoreBndr]
        -- The result binders have one-shot-ness set that they might not have had originally.
        -- This happens in (build (\cn -> e)).  Here the occurrence analyser
        -- linearity context knows that c,n are one-shot, and it records that fact in
        -- the binder. This is useful to guide subsequent float-in/float-out tranformations

oneShotGroup (OccEnv { occ_ctxt = ctxt }) bndrs
  = go ctxt bndrs []
  where
    go _ [] rev_bndrs = reverse rev_bndrs

    go (lin_ctxt:ctxt) (bndr:bndrs) rev_bndrs
        | isId bndr = go ctxt bndrs (bndr':rev_bndrs)
        where
          bndr' | lin_ctxt  = setOneShotLambda bndr
                | otherwise = bndr

    go ctxt (bndr:bndrs) rev_bndrs = go ctxt bndrs (bndr:rev_bndrs)

addAppCtxt :: OccEnv -> [Arg CoreBndr] -> OccEnv
addAppCtxt env@(OccEnv { occ_ctxt = ctxt }) args
  = env { occ_ctxt = replicate (valArgCount args) True ++ ctxt }
\end{code}


\begin{code}
transClosureFV :: UniqFM VarSet -> UniqFM VarSet
-- If (f,g), (g,h) are in the input, then (f,h) is in the output
--                                   as well as (f,g), (g,h)
transClosureFV env
  | no_change = env
  | otherwise = transClosureFV (listToUFM new_fv_list)
  where
    (no_change, new_fv_list) = mapAccumL bump True (ufmToList env)
    bump no_change (b,fvs)
      | no_change_here = (no_change, (b,fvs))
      | otherwise      = (False,     (b,new_fvs))
      where
        (new_fvs, no_change_here) = extendFvs env fvs

-------------
extendFvs_ :: UniqFM VarSet -> VarSet -> VarSet
extendFvs_ env s = fst (extendFvs env s)   -- Discard the Bool flag

extendFvs :: UniqFM VarSet -> VarSet -> (VarSet, Bool)
-- (extendFVs env s) returns 
--     (s `union` env(s), env(s) `subset` s)
extendFvs env s
  | isNullUFM env 
  = (s, True)
  | otherwise
  = (s `unionVarSet` extras, extras `subVarSet` s)
  where
    extras :: VarSet	-- env(s)
    extras = foldUFM unionVarSet emptyVarSet $
             intersectUFM_C (\x _ -> x) env s
\end{code}


%************************************************************************
%*                                                                      *
                    ProxyEnv									
%*                                                                      *
%************************************************************************

\begin{code}
data ProxyEnv	-- See Note [ProxyEnv]
   = PE (IdEnv	-- Domain = scrutinee variables
           (Id,                  -- The scrutinee variable again
            [(Id,Coercion)])) 	 -- The case binders that it maps to
        VarSet	-- Free variables of both range and domain
\end{code}

Note [ProxyEnv]
~~~~~~~~~~~~~~~
The ProxyEnv keeps track of the connection between case binders and
scrutinee.  Specifically, if
     sc |-> (sc, [...(cb, co)...])
is a binding in the ProxyEnv, then
     cb = sc |> coi
Typically we add such a binding when encountering the case expression
     case (sc |> coi) of cb { ... }

Things to note:
  * The domain of the ProxyEnv is the variable (or casted variable) 
    scrutinees of enclosing cases.  This is additionally used
    to ensure we gather occurrence info even for GlobalId scrutinees;
    see Note [Binder swap for GlobalId scrutinee]

  * The ProxyEnv is just an optimisation; you can throw away any 
    element without losing correctness.  And we do so when pushing
    it inside a binding (see trimProxyEnv).

  * One scrutinee might map to many case binders:  Eg
      case sc of cb1 { DEFAULT -> ....case sc of cb2 { ... } .. }

INVARIANTS
 * If sc1 |-> (sc2, [...(cb, co)...]), then sc1==sc2
   It's a UniqFM and we sometimes need the domain Id

 * Any particular case binder 'cb' occurs only once in entire range

 * No loops

The Main Reason for having a ProxyEnv is so that when we encounter
    case e of cb { pi -> ri }
we can find all the in-scope variables derivable from 'cb', 
and effectively add let-bindings for them (or at least for the
ones *mentioned* in ri) thus:
    case e of cb { pi -> let { x = ..cb..; y = ...cb.. }
                         in ri }
In this way we'll replace occurrences of 'x', 'y' with 'cb',
which implements the Binder-swap idea (see Note [Binder swap])

The function getProxies finds these bindings; then we 
add just the necessary ones, using wrapProxy. 

Note [Binder swap]
~~~~~~~~~~~~~~~~~~
We do these two transformations right here:

 (1)   case x of b { pi -> ri }
    ==>
      case x of b { pi -> let x=b in ri }

 (2)  case (x |> co) of b { pi -> ri }
    ==>
      case (x |> co) of b { pi -> let x = b |> sym co in ri }

    Why (2)?  See Note [Case of cast]

In both cases, in a particular alternative (pi -> ri), we only 
add the binding if
  (a) x occurs free in (pi -> ri)
	(ie it occurs in ri, but is not bound in pi)
  (b) the pi does not bind b (or the free vars of co)
We need (a) and (b) for the inserted binding to be correct.

For the alternatives where we inject the binding, we can transfer
all x's OccInfo to b.  And that is the point.

Notice that 
  * The deliberate shadowing of 'x'. 
  * That (a) rapidly becomes false, so no bindings are injected.

The reason for doing these transformations here is because it allows
us to adjust the OccInfo for 'x' and 'b' as we go.

  * Suppose the only occurrences of 'x' are the scrutinee and in the
    ri; then this transformation makes it occur just once, and hence
    get inlined right away.

  * If we do this in the Simplifier, we don't know whether 'x' is used
    in ri, so we are forced to pessimistically zap b's OccInfo even
    though it is typically dead (ie neither it nor x appear in the
    ri).  There's nothing actually wrong with zapping it, except that
    it's kind of nice to know which variables are dead.  My nose
    tells me to keep this information as robustly as possible.

The Maybe (Id,CoreExpr) passed to occAnalAlt is the extra let-binding
{x=b}; it's Nothing if the binder-swap doesn't happen.

There is a danger though.  Consider
      let v = x +# y
      in case (f v) of w -> ...v...v...
And suppose that (f v) expands to just v.  Then we'd like to
use 'w' instead of 'v' in the alternative.  But it may be too
late; we may have substituted the (cheap) x+#y for v in the 
same simplifier pass that reduced (f v) to v.

I think this is just too bad.  CSE will recover some of it.

Note [Case of cast]
~~~~~~~~~~~~~~~~~~~
Consider        case (x `cast` co) of b { I# ->
                ... (case (x `cast` co) of {...}) ...
We'd like to eliminate the inner case.  That is the motivation for
equation (2) in Note [Binder swap].  When we get to the inner case, we
inline x, cancel the casts, and away we go.

Note [Binder swap on GlobalId scrutinees]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When the scrutinee is a GlobalId we must take care in two ways

 i) In order to *know* whether 'x' occurs free in the RHS, we need its
    occurrence info. BUT, we don't gather occurrence info for
    GlobalIds.  That's one use for the (small) occ_proxy env in OccEnv is
    for: it says "gather occurrence info for these.

 ii) We must call localiseId on 'x' first, in case it's a GlobalId, or
     has an External Name. See, for example, SimplEnv Note [Global Ids in
     the substitution].

Note [getProxies is subtle]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The code for getProxies isn't all that obvious. Consider

  case v |> cov  of x { DEFAULT ->
  case x |> cox1 of y { DEFAULT ->
  case x |> cox2 of z { DEFAULT -> r

These will give us a ProxyEnv looking like:
  x |-> (x, [(y, cox1), (z, cox2)])
  v |-> (v, [(x, cov)])

From this we want to extract the bindings
    x = z |> sym cox2
    v = x |> sym cov
    y = x |> cox1

Notice that later bindings may mention earlier ones, and that
we need to go "both ways".

Note [Zap case binders in proxy bindings]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
From the original
     case x of cb(dead) { p -> ...x... }
we will get
     case x of cb(live) { p -> let x = cb in ...x... }

Core Lint never expects to find an *occurence* of an Id marked
as Dead, so we must zap the OccInfo on cb before making the 
binding x = cb.  See Trac #5028.

Historical note [no-case-of-case]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We *used* to suppress the binder-swap in case expressions when 
-fno-case-of-case is on.  Old remarks:
    "This happens in the first simplifier pass,
    and enhances full laziness.  Here's the bad case:
            f = \ y -> ...(case x of I# v -> ...(case x of ...) ... )
    If we eliminate the inner case, we trap it inside the I# v -> arm,
    which might prevent some full laziness happening.  I've seen this
    in action in spectral/cichelli/Prog.hs:
             [(m,n) | m <- [1..max], n <- [1..max]]
    Hence the check for NoCaseOfCase."
However, now the full-laziness pass itself reverses the binder-swap, so this
check is no longer necessary.

Historical note [Suppressing the case binder-swap]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
This old note describes a problem that is also fixed by doing the
binder-swap in OccAnal:

    There is another situation when it might make sense to suppress the
    case-expression binde-swap. If we have

        case x of w1 { DEFAULT -> case x of w2 { A -> e1; B -> e2 }
                       ...other cases .... }

    We'll perform the binder-swap for the outer case, giving

        case x of w1 { DEFAULT -> case w1 of w2 { A -> e1; B -> e2 }
                       ...other cases .... }

    But there is no point in doing it for the inner case, because w1 can't
    be inlined anyway.  Furthermore, doing the case-swapping involves
    zapping w2's occurrence info (see paragraphs that follow), and that
    forces us to bind w2 when doing case merging.  So we get

        case x of w1 { A -> let w2 = w1 in e1
                       B -> let w2 = w1 in e2
                       ...other cases .... }

    This is plain silly in the common case where w2 is dead.

    Even so, I can't see a good way to implement this idea.  I tried
    not doing the binder-swap if the scrutinee was already evaluated
    but that failed big-time:

            data T = MkT !Int

            case v of w  { MkT x ->
            case x of x1 { I# y1 ->
            case x of x2 { I# y2 -> ...

    Notice that because MkT is strict, x is marked "evaluated".  But to
    eliminate the last case, we must either make sure that x (as well as
    x1) has unfolding MkT y1.  THe straightforward thing to do is to do
    the binder-swap.  So this whole note is a no-op.

It's fixed by doing the binder-swap in OccAnal because we can do the
binder-swap unconditionally and still get occurrence analysis
information right.

\begin{code}
extendProxyEnv :: ProxyEnv -> Id -> Coercion -> Id -> ProxyEnv
-- (extendPE x co y) typically arises from 
--		  case (x |> co) of y { ... }
-- It extends the proxy env with the binding 
-- 	               y = x |> co
extendProxyEnv pe scrut co case_bndr
  | scrut == case_bndr = PE env1 fvs1	-- If case_bndr shadows scrut,
  | otherwise          = PE env2 fvs2	--   don't extend
  where
    PE env1 fvs1 = trimProxyEnv pe [case_bndr]
    env2 = extendVarEnv_Acc add single env1 scrut1 (case_bndr,co)
    single cb_co = (scrut1, [cb_co]) 
    add cb_co (x, cb_cos) = (x, cb_co:cb_cos)
    fvs2 = fvs1 `unionVarSet`  tyCoVarsOfCo co
		`extendVarSet` case_bndr
		`extendVarSet` scrut1

    scrut1 = mkLocalId (localiseName (idName scrut)) (idType scrut)
	-- Localise the scrut_var before shadowing it; we're making a 
	-- new binding for it, and it might have an External Name, or
	-- even be a GlobalId; Note [Binder swap on GlobalId scrutinees]
	-- Also we don't want any INLINE or NOINLINE pragmas!

-----------
type ProxyBind = (Id, Id, Coercion)
     -- (scrut variable, case-binder variable, coercion)

getProxies :: OccEnv -> Id -> Bag ProxyBind
-- Return a bunch of bindings [...(xi,ei)...] 
-- such that  let { ...; xi=ei; ... } binds the xi using y alone
-- See Note [getProxies is subtle]
getProxies (OccEnv { occ_proxy = PE pe _ }) case_bndr
  = -- pprTrace "wrapProxies" (ppr case_bndr) $
    go_fwd case_bndr
  where
    fwd_pe :: IdEnv (Id, Coercion)
    fwd_pe = foldVarEnv add1 emptyVarEnv pe
           where
             add1 (x,ycos) env = foldr (add2 x) env ycos
             add2 x (y,co) env = extendVarEnv env y (x,co)

    go_fwd :: Id -> Bag ProxyBind
	-- Return bindings derivable from case_bndr
    go_fwd case_bndr = -- pprTrace "go_fwd" (vcat [ppr case_bndr, text "fwd_pe =" <+> ppr fwd_pe, 
                       --                         text "pe =" <+> ppr pe]) $ 
                       go_fwd' case_bndr

    go_fwd' case_bndr
        | Just (scrut, co) <- lookupVarEnv fwd_pe case_bndr
        = unitBag (scrut,  case_bndr, mkSymCo co)
	  `unionBags` go_fwd scrut
          `unionBags` go_bwd scrut [pr | pr@(cb,_) <- lookup_bwd scrut
                                       , cb /= case_bndr]
        | otherwise 
        = emptyBag

    lookup_bwd :: Id -> [(Id, Coercion)]
	-- Return case_bndrs that are connected to scrut 
    lookup_bwd scrut = case lookupVarEnv pe scrut of
          		  Nothing          -> []
	  		  Just (_, cb_cos) -> cb_cos

    go_bwd :: Id -> [(Id, Coercion)] -> Bag ProxyBind
    go_bwd scrut cb_cos = foldr (unionBags . go_bwd1 scrut) emptyBag cb_cos

    go_bwd1 :: Id -> (Id, Coercion) -> Bag ProxyBind
    go_bwd1 scrut (case_bndr, co) 
       = -- pprTrace "go_bwd1" (ppr case_bndr) $
         unitBag (case_bndr, scrut, co)
	 `unionBags` go_bwd case_bndr (lookup_bwd case_bndr)

-----------
mkAltEnv :: OccEnv -> CoreExpr -> Id -> OccEnv
-- Does two things: a) makes the occ_ctxt = OccVanilla
-- 	    	    b) extends the ProxyEnv if possible
mkAltEnv env scrut cb
  = env { occ_encl  = OccVanilla, occ_proxy = pe' }
  where
    pe  = occ_proxy env
    pe' = case scrut of
             Var v           -> extendProxyEnv pe v (mkReflCo (idType v)) cb
             Cast (Var v) co -> extendProxyEnv pe v co                    cb
             _other          -> trimProxyEnv pe [cb]

-----------
trimOccEnv :: OccEnv -> [CoreBndr] -> OccEnv
trimOccEnv env bndrs = env { occ_proxy = trimProxyEnv (occ_proxy env) bndrs }

-----------
trimProxyEnv :: ProxyEnv -> [CoreBndr] -> ProxyEnv
-- We are about to push this ProxyEnv inside a binding for 'bndrs'
-- So dump any ProxyEnv bindings which mention any of the bndrs
trimProxyEnv (PE pe fvs) bndrs 
  | not (bndr_set `intersectsVarSet` fvs) 
  = PE pe fvs
  | otherwise
  = PE pe' (fvs `minusVarSet` bndr_set)
  where
    pe' = mapVarEnv trim pe
    bndr_set = mkVarSet bndrs
    trim (scrut, cb_cos) | scrut `elemVarSet` bndr_set = (scrut, [])
			 | otherwise = (scrut, filterOut discard cb_cos)
    discard (cb,co) = bndr_set `intersectsVarSet` 
                      extendVarSet (tyCoVarsOfCo co) cb
\end{code}


%************************************************************************
%*                                                                      *
\subsection[OccurAnal-types]{OccEnv}
%*                                                                      *
%************************************************************************

\begin{code}
type UsageDetails = IdEnv OccInfo       -- A finite map from ids to their usage
		-- INVARIANT: never IAmDead
		-- (Deadness is signalled by not being in the map at all)

(+++), combineAltsUsageDetails
        :: UsageDetails -> UsageDetails -> UsageDetails

(+++) usage1 usage2
  = plusVarEnv_C addOccInfo usage1 usage2

combineAltsUsageDetails usage1 usage2
  = plusVarEnv_C orOccInfo usage1 usage2

addOneOcc :: UsageDetails -> Id -> OccInfo -> UsageDetails
addOneOcc usage id info
  = plusVarEnv_C addOccInfo usage (unitVarEnv id info)
        -- ToDo: make this more efficient

emptyDetails :: UsageDetails
emptyDetails = (emptyVarEnv :: UsageDetails)

usedIn :: Id -> UsageDetails -> Bool
v `usedIn` details = isExportedId v || v `elemVarEnv` details

type IdWithOccInfo = Id

tagLamBinders :: UsageDetails          -- Of scope
              -> [Id]                  -- Binders
              -> (UsageDetails,        -- Details with binders removed
                 [IdWithOccInfo])    -- Tagged binders
-- Used for lambda and case binders
-- It copes with the fact that lambda bindings can have InlineRule 
-- unfoldings, used for join points
tagLamBinders usage binders = usage' `seq` (usage', bndrs')
  where
    (usage', bndrs') = mapAccumR tag_lam usage binders
    tag_lam usage bndr = (usage2, setBinderOcc usage bndr)
      where
        usage1 = usage `delVarEnv` bndr
        usage2 | isId bndr = addIdOccs usage1 (idUnfoldingVars bndr)
               | otherwise = usage1

tagBinder :: UsageDetails           -- Of scope
          -> Id                     -- Binders
          -> (UsageDetails,         -- Details with binders removed
              IdWithOccInfo)        -- Tagged binders

tagBinder usage binder
 = let
     usage'  = usage `delVarEnv` binder
     binder' = setBinderOcc usage binder
   in
   usage' `seq` (usage', binder')

setBinderOcc :: UsageDetails -> CoreBndr -> CoreBndr
setBinderOcc usage bndr
  | isTyVar bndr      = bndr
  | isExportedId bndr = case idOccInfo bndr of
                          NoOccInfo -> bndr
                          _         -> setIdOccInfo bndr NoOccInfo
            -- Don't use local usage info for visible-elsewhere things
            -- BUT *do* erase any IAmALoopBreaker annotation, because we're
            -- about to re-generate it and it shouldn't be "sticky"

  | otherwise = setIdOccInfo bndr occ_info
  where
    occ_info = lookupVarEnv usage bndr `orElse` IAmDead
\end{code}


%************************************************************************
%*                                                                      *
\subsection{Operations over OccInfo}
%*                                                                      *
%************************************************************************

\begin{code}
mkOneOcc :: OccEnv -> Id -> InterestingCxt -> UsageDetails
mkOneOcc env id int_cxt
  | isLocalId id 
  = unitVarEnv id (OneOcc False True int_cxt)

  | PE env _ <- occ_proxy env
  , id `elemVarEnv` env 
  = unitVarEnv id NoOccInfo

  | otherwise
  = emptyDetails

markMany, markInsideLam, markInsideSCC :: OccInfo -> OccInfo

markMany _  = NoOccInfo

markInsideSCC occ = markMany occ

markInsideLam (OneOcc _ one_br int_cxt) = OneOcc True one_br int_cxt
markInsideLam occ                       = occ

addOccInfo, orOccInfo :: OccInfo -> OccInfo -> OccInfo

addOccInfo a1 a2  = ASSERT( not (isDeadOcc a1 || isDeadOcc a2) )
		    NoOccInfo	-- Both branches are at least One
				-- (Argument is never IAmDead)

-- (orOccInfo orig new) is used
-- when combining occurrence info from branches of a case

orOccInfo (OneOcc in_lam1 _ int_cxt1)
          (OneOcc in_lam2 _ int_cxt2)
  = OneOcc (in_lam1 || in_lam2)
           False        -- False, because it occurs in both branches
           (int_cxt1 && int_cxt2)
orOccInfo a1 a2 = ASSERT( not (isDeadOcc a1 || isDeadOcc a2) )
		  NoOccInfo
\end{code}
