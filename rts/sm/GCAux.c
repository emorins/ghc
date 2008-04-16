/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team 1998-2008
 *
 * Functions called from outside the GC need to be separate from GC.c, 
 * because GC.c is compiled with register variable(s).
 *
 * ---------------------------------------------------------------------------*/

#include "Rts.h"
#include "Storage.h"
#include "MBlock.h"
#include "GC.h"
#include "Compact.h"
#include "Task.h"
#include "Capability.h"
#include "Trace.h"
#include "Schedule.h"
// DO NOT include "GCThread.h", we don't want the register variable

/* -----------------------------------------------------------------------------
   isAlive determines whether the given closure is still alive (after
   a garbage collection) or not.  It returns the new address of the
   closure if it is alive, or NULL otherwise.

   NOTE: Use it before compaction only!
         It untags and (if needed) retags pointers to closures.
   -------------------------------------------------------------------------- */

StgClosure *
isAlive(StgClosure *p)
{
  const StgInfoTable *info;
  bdescr *bd;
  StgWord tag;
  StgClosure *q;

  while (1) {
    /* The tag and the pointer are split, to be merged later when needed. */
    tag = GET_CLOSURE_TAG(p);
    q = UNTAG_CLOSURE(p);

    ASSERT(LOOKS_LIKE_CLOSURE_PTR(q));
    info = get_itbl(q);

    // ignore static closures 
    //
    // ToDo: for static closures, check the static link field.
    // Problem here is that we sometimes don't set the link field, eg.
    // for static closures with an empty SRT or CONSTR_STATIC_NOCAFs.
    //
    if (!HEAP_ALLOCED(q)) {
	return p;
    }

    // ignore closures in generations that we're not collecting. 
    bd = Bdescr((P_)q);

    // if it's a pointer into to-space, then we're done
    if (bd->flags & BF_EVACUATED) {
	return p;
    }

    // large objects use the evacuated flag
    if (bd->flags & BF_LARGE) {
	return NULL;
    }

    // check the mark bit for compacted steps
    if ((bd->flags & BF_COMPACTED) && is_marked((P_)q,bd)) {
	return p;
    }

    switch (info->type) {

    case IND:
    case IND_STATIC:
    case IND_PERM:
    case IND_OLDGEN:		// rely on compatible layout with StgInd 
    case IND_OLDGEN_PERM:
      // follow indirections 
      p = ((StgInd *)q)->indirectee;
      continue;

    case EVACUATED:
      // alive! 
      return ((StgEvacuated *)q)->evacuee;

    case TSO:
      if (((StgTSO *)q)->what_next == ThreadRelocated) {
	p = (StgClosure *)((StgTSO *)q)->link;
	continue;
      } 
      return NULL;

    default:
      // dead. 
      return NULL;
    }
  }
}

/* -----------------------------------------------------------------------------
   Reverting CAFs
   -------------------------------------------------------------------------- */

void
revertCAFs( void )
{
    StgIndStatic *c;

    for (c = (StgIndStatic *)revertible_caf_list; c != NULL; 
	 c = (StgIndStatic *)c->static_link) 
    {
	SET_INFO(c, c->saved_info);
	c->saved_info = NULL;
	// could, but not necessary: c->static_link = NULL; 
    }
    revertible_caf_list = NULL;
}

void
markCAFs (evac_fn evac, void *user)
{
    StgIndStatic *c;

    for (c = (StgIndStatic *)caf_list; c != NULL; 
	 c = (StgIndStatic *)c->static_link) 
    {
	evac(user, &c->indirectee);
    }
    for (c = (StgIndStatic *)revertible_caf_list; c != NULL; 
	 c = (StgIndStatic *)c->static_link) 
    {
	evac(user, &c->indirectee);
    }
}