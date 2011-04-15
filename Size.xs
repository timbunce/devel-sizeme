#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

/* Not yet in ppport.h */
#ifndef CvISXSUB
#  define CvISXSUB(cv)  (CvXSUB(cv) ? TRUE : FALSE)
#endif

#ifdef _MSC_VER 
/* "structured exception" handling is a Microsoft extension to C and C++.
   It's *not* C++ exception handling - C++ exception handling can't capture
   SEGVs and suchlike, whereas this can. There's no known analagous
    functionality on other platforms.  */
#  include <excpt.h>
#  define TRY_TO_CATCH_SEGV __try
#  define CAUGHT_EXCEPTION __except(EXCEPTION EXCEPTION_EXECUTE_HANDLER)
#else
#  define TRY_TO_CATCH_SEGV if(1)
#  define CAUGHT_EXCEPTION else
#endif

#ifdef __GNUC__
# define __attribute__(x)
#endif

#if 0 && defined(DEBUGGING)
#define dbg_printf(x) printf x
#else
#define dbg_printf(x)
#endif

#define TAG /* printf( "# %s(%d)\n", __FILE__, __LINE__ ) */
#define carp puts

/* The idea is to have a tree structure to store 1 bit per possible pointer
   address. The lowest 16 bits are stored in a block of 8092 bytes.
   The blocks are in a 256-way tree, indexed by the reset of the pointer.
   This can cope with 32 and 64 bit pointers, and any address space layout,
   without excessive memory needs. The assumption is that your CPU cache
   works :-) (And that we're not going to bust it)  */

#define ALIGN_BITS  ( sizeof(void*) >> 1 )
#define BYTE_BITS    3
#define LEAF_BITS   (16 - BYTE_BITS)
#define LEAF_MASK   0x1FFF

struct state {
    bool regex_whine;
    bool fm_whine;
    bool dangle_whine;
    bool go_yell;
    /* My hunch (not measured) is that for most architectures pointers will
       start with 0 bits, hence the start of this array will be hot, and the
       end unused. So put the flags next to the hot end.  */
    void *tracking[256];
};

/* 
    Checks to see if thing is in the bitstring. 
    Returns true or false, and
    notes thing in the segmented bitstring.
 */
static bool
check_new(struct state *st, const void *const p) {
    unsigned int bits = 8 * sizeof(void*);
    const size_t raw_p = PTR2nat(p);
    /* This effectively rotates the value right by the number of low always-0
       bits in an aligned pointer. The assmption is that most (if not all)
       pointers are aligned, and these will be in the same chain of nodes
       (and hence hot in the cache) but we can still deal with any unaligned
       pointers.  */
    const size_t cooked_p
	= (raw_p >> ALIGN_BITS) | (raw_p << (bits - BYTE_BITS));
    const U8 this_bit = 1 << (cooked_p & 0x7);
    U8 **leaf_p;
    U8 *leaf;
    unsigned int i;
    void **tv_p = (void **) (st->tracking);

    assert(st);
    if (NULL == p) return FALSE;
    TRY_TO_CATCH_SEGV { 
        const char c = *(const char *)p;
    }
    CAUGHT_EXCEPTION {
        if (st->dangle_whine) 
            warn( "Devel::Size: Encountered invalid pointer: %p\n", p );
        return FALSE;
    }
    TAG;    

    bits -= 8;
    /* bits now 24 (32 bit pointers) or 56 (64 bit pointers) */

    /* First level is always present.  */
    do {
	i = (unsigned int)((cooked_p >> bits) & 0xFF);
	if (!tv_p[i])
	    Newxz(tv_p[i], 256, void *);
	tv_p = (void **)(tv_p[i]);
	bits -= 8;
    } while (bits > LEAF_BITS + BYTE_BITS);
    /* bits now 16 always */
    assert(bits == 16);
    leaf_p = (U8 **)tv_p;
    i = (unsigned int)((cooked_p >> bits) & 0xFF);
    if (!leaf_p[i])
	Newxz(leaf_p[i], 1 << LEAF_BITS, U8);
    leaf = leaf_p[i];

    TAG;    

    i = (unsigned int)((cooked_p >> BYTE_BITS) & LEAF_MASK);

    if(leaf[i] & this_bit)
	return FALSE;

    leaf[i] |= this_bit;
    return TRUE;
}

static void
free_tracking_at(void **tv, int level)
{
    int i = 255;

    if (--level) {
	/* Nodes */
	do {
	    if (tv[i]) {
		free_tracking_at(tv[i], level);
		Safefree(tv[i]);
	    }
	} while (i--);
    } else {
	/* Leaves */
	do {
	    if (tv[i])
		Safefree(tv[i]);
	} while (i--);
    }
}

static void
free_state(struct state *st)
{
    const int top_level = (sizeof(void *) * 8 - LEAF_BITS - BYTE_BITS) / 8;
    free_tracking_at((void **)st->tracking, top_level);
    Safefree(st);
}

static UV thing_size(pTHX_ const SV *const, struct state *);
typedef enum {
    OPc_NULL,   /* 0 */
    OPc_BASEOP, /* 1 */
    OPc_UNOP,   /* 2 */
    OPc_BINOP,  /* 3 */
    OPc_LOGOP,  /* 4 */
    OPc_LISTOP, /* 5 */
    OPc_PMOP,   /* 6 */
    OPc_SVOP,   /* 7 */
    OPc_PADOP,  /* 8 */
    OPc_PVOP,   /* 9 */
    OPc_LOOP,   /* 10 */
    OPc_COP /* 11 */
} opclass;

static opclass
cc_opclass(const OP * const o)
{
    if (!o)
    return OPc_NULL;
    TRY_TO_CATCH_SEGV {
        if (o->op_type == 0)
        return (o->op_flags & OPf_KIDS) ? OPc_UNOP : OPc_BASEOP;

        if (o->op_type == OP_SASSIGN)
        return ((o->op_private & OPpASSIGN_BACKWARDS) ? OPc_UNOP : OPc_BINOP);

    #ifdef USE_ITHREADS
        if (o->op_type == OP_GV || o->op_type == OP_GVSV || o->op_type == OP_AELEMFAST)
        return OPc_PADOP;
    #endif

        if ((o->op_type == OP_TRANS)) {
          return OPc_BASEOP;
        }

        switch (PL_opargs[o->op_type] & OA_CLASS_MASK) {
        case OA_BASEOP: TAG;
        return OPc_BASEOP;

        case OA_UNOP: TAG;
        return OPc_UNOP;

        case OA_BINOP: TAG;
        return OPc_BINOP;

        case OA_LOGOP: TAG;
        return OPc_LOGOP;

        case OA_LISTOP: TAG;
        return OPc_LISTOP;

        case OA_PMOP: TAG;
        return OPc_PMOP;

        case OA_SVOP: TAG;
        return OPc_SVOP;

        case OA_PADOP: TAG;
        return OPc_PADOP;

        case OA_PVOP_OR_SVOP: TAG;
            /*
             * Character translations (tr///) are usually a PVOP, keeping a 
             * pointer to a table of shorts used to look up translations.
             * Under utf8, however, a simple table isn't practical; instead,
             * the OP is an SVOP, and the SV is a reference to a swash
             * (i.e., an RV pointing to an HV).
             */
        return (o->op_private & (OPpTRANS_TO_UTF|OPpTRANS_FROM_UTF))
            ? OPc_SVOP : OPc_PVOP;

        case OA_LOOP: TAG;
        return OPc_LOOP;

        case OA_COP: TAG;
        return OPc_COP;

        case OA_BASEOP_OR_UNOP: TAG;
        /*
         * UNI(OP_foo) in toke.c returns token UNI or FUNC1 depending on
         * whether parens were seen. perly.y uses OPf_SPECIAL to
         * signal whether a BASEOP had empty parens or none.
         * Some other UNOPs are created later, though, so the best
         * test is OPf_KIDS, which is set in newUNOP.
         */
        return (o->op_flags & OPf_KIDS) ? OPc_UNOP : OPc_BASEOP;

        case OA_FILESTATOP: TAG;
        /*
         * The file stat OPs are created via UNI(OP_foo) in toke.c but use
         * the OPf_REF flag to distinguish between OP types instead of the
         * usual OPf_SPECIAL flag. As usual, if OPf_KIDS is set, then we
         * return OPc_UNOP so that walkoptree can find our children. If
         * OPf_KIDS is not set then we check OPf_REF. Without OPf_REF set
         * (no argument to the operator) it's an OP; with OPf_REF set it's
         * an SVOP (and op_sv is the GV for the filehandle argument).
         */
        return ((o->op_flags & OPf_KIDS) ? OPc_UNOP :
    #ifdef USE_ITHREADS
            (o->op_flags & OPf_REF) ? OPc_PADOP : OPc_BASEOP);
    #else
            (o->op_flags & OPf_REF) ? OPc_SVOP : OPc_BASEOP);
    #endif
        case OA_LOOPEXOP: TAG;
        /*
         * next, last, redo, dump and goto use OPf_SPECIAL to indicate that a
         * label was omitted (in which case it's a BASEOP) or else a term was
         * seen. In this last case, all except goto are definitely PVOP but
         * goto is either a PVOP (with an ordinary constant label), an UNOP
         * with OPf_STACKED (with a non-constant non-sub) or an UNOP for
         * OP_REFGEN (with goto &sub) in which case OPf_STACKED also seems to
         * get set.
         */
        if (o->op_flags & OPf_STACKED)
            return OPc_UNOP;
        else if (o->op_flags & OPf_SPECIAL)
            return OPc_BASEOP;
        else
            return OPc_PVOP;
        }
        warn("Devel::Size: Can't determine class of operator %s, assuming BASEOP\n",
         PL_op_name[o->op_type]);
    }
    CAUGHT_EXCEPTION { }
    return OPc_BASEOP;
}


#if !defined(NV)
#define NV double
#endif

/* Figure out how much magic is attached to the SV and return the
   size */
IV magic_size(const SV * const thing, struct state *st) {
  IV total_size = 0;
  MAGIC *magic_pointer;

  /* Is there any? */
  if (!SvMAGIC(thing)) {
    /* No, bail */
    return 0;
  }

  /* Get the base magic pointer */
  magic_pointer = SvMAGIC(thing);

  /* Have we seen the magic pointer? */
  while (magic_pointer && check_new(st, magic_pointer)) {
    total_size += sizeof(MAGIC);

    TRY_TO_CATCH_SEGV {
        /* Have we seen the magic vtable? */
        if (magic_pointer->mg_virtual &&
        check_new(st, magic_pointer->mg_virtual)) {
          total_size += sizeof(MGVTBL);
        }

        /* Get the next in the chain */
        magic_pointer = magic_pointer->mg_moremagic;
    }
    CAUGHT_EXCEPTION { 
        if (st->dangle_whine) 
            warn( "Devel::Size: Encountered bad magic at: %p\n", magic_pointer );
    }
  }
  return total_size;
}

UV regex_size(const REGEXP * const baseregex, struct state *st) {
  UV total_size = 0;

  total_size += sizeof(REGEXP);
#if (PERL_VERSION < 11)     
  /* Note the size of the paren offset thing */
  total_size += sizeof(I32) * baseregex->nparens * 2;
  total_size += strlen(baseregex->precomp);
#else
  total_size += sizeof(struct regexp);
  total_size += sizeof(I32) * SvANY(baseregex)->nparens * 2;
  /*total_size += strlen(SvANY(baseregex)->subbeg);*/
#endif
  if (st->go_yell && !st->regex_whine) {
    carp("Devel::Size: Calculated sizes for compiled regexes are incompatible, and probably always will be");
    st->regex_whine = 1;
  }

  return total_size;
}

static UV
op_size(pTHX_ const OP * const baseop, struct state *st) {
  UV total_size = 0;
  TRY_TO_CATCH_SEGV {
      TAG;
      if (check_new(st, baseop->op_next)) {
           total_size += op_size(aTHX_ baseop->op_next, st);
      }
      TAG;
      switch (cc_opclass(baseop)) {
      case OPc_BASEOP: TAG;
        total_size += sizeof(struct op);
        TAG;break;
      case OPc_UNOP: TAG;
        total_size += sizeof(struct unop);
        if (check_new(st, cUNOPx(baseop)->op_first)) {
          total_size += op_size(aTHX_ cUNOPx(baseop)->op_first, st);
        }
        TAG;break;
      case OPc_BINOP: TAG;
        total_size += sizeof(struct binop);
        if (check_new(st, cBINOPx(baseop)->op_first)) {
          total_size += op_size(aTHX_ cBINOPx(baseop)->op_first, st);
        }  
        if (check_new(st, cBINOPx(baseop)->op_last)) {
          total_size += op_size(aTHX_ cBINOPx(baseop)->op_last, st);
        }
        TAG;break;
      case OPc_LOGOP: TAG;
        total_size += sizeof(struct logop);
        if (check_new(st, cLOGOPx(baseop)->op_first)) {
          total_size += op_size(aTHX_ cBINOPx(baseop)->op_first, st);
        }  
        if (check_new(st, cLOGOPx(baseop)->op_other)) {
          total_size += op_size(aTHX_ cLOGOPx(baseop)->op_other, st);
        }
        TAG;break;
      case OPc_LISTOP: TAG;
        total_size += sizeof(struct listop);
        if (check_new(st, cLISTOPx(baseop)->op_first)) {
          total_size += op_size(aTHX_ cLISTOPx(baseop)->op_first, st);
        }  
        if (check_new(st, cLISTOPx(baseop)->op_last)) {
          total_size += op_size(aTHX_ cLISTOPx(baseop)->op_last, st);
        }
        TAG;break;
      case OPc_PMOP: TAG;
        total_size += sizeof(struct pmop);
        if (check_new(st, cPMOPx(baseop)->op_first)) {
          total_size += op_size(aTHX_ cPMOPx(baseop)->op_first, st);
        }  
        if (check_new(st, cPMOPx(baseop)->op_last)) {
          total_size += op_size(aTHX_ cPMOPx(baseop)->op_last, st);
        }
#if PERL_VERSION < 9 || (PERL_VERSION == 9 && PERL_SUBVERSION < 5)
        if (check_new(st, cPMOPx(baseop)->op_pmreplroot)) {
          total_size += op_size(aTHX_ cPMOPx(baseop)->op_pmreplroot, st);
        }
        if (check_new(st, cPMOPx(baseop)->op_pmreplstart)) {
          total_size += op_size(aTHX_ cPMOPx(baseop)->op_pmreplstart, st);
        }
        if (check_new(st, cPMOPx(baseop)->op_pmnext)) {
          total_size += op_size(aTHX_ (OP *)cPMOPx(baseop)->op_pmnext, st);
        }
#endif
        /* This is defined away in perl 5.8.x, but it is in there for
           5.6.x */
#ifdef PM_GETRE
        if (check_new(st, PM_GETRE((cPMOPx(baseop))))) {
          total_size += regex_size(PM_GETRE(cPMOPx(baseop)), st);
        }
#else
        if (check_new(st, cPMOPx(baseop)->op_pmregexp)) {
          total_size += regex_size(cPMOPx(baseop)->op_pmregexp, st);
        }
#endif
        TAG;break;
      case OPc_SVOP: TAG;
        total_size += sizeof(struct pmop);
        if (check_new(st, cSVOPx(baseop)->op_sv)) {
          total_size += thing_size(aTHX_ cSVOPx(baseop)->op_sv, st);
        }
        TAG;break;
      case OPc_PADOP: TAG;
        total_size += sizeof(struct padop);
        TAG;break;
      case OPc_PVOP: TAG;
        if (check_new(st, cPVOPx(baseop)->op_pv)) {
          total_size += strlen(cPVOPx(baseop)->op_pv);
        }
      case OPc_LOOP: TAG;
        total_size += sizeof(struct loop);
        if (check_new(st, cLOOPx(baseop)->op_first)) {
          total_size += op_size(aTHX_ cLOOPx(baseop)->op_first, st);
        }  
        if (check_new(st, cLOOPx(baseop)->op_last)) {
          total_size += op_size(aTHX_ cLOOPx(baseop)->op_last, st);
        }
        if (check_new(st, cLOOPx(baseop)->op_redoop)) {
          total_size += op_size(aTHX_ cLOOPx(baseop)->op_redoop, st);
        }  
        if (check_new(st, cLOOPx(baseop)->op_nextop)) {
          total_size += op_size(aTHX_ cLOOPx(baseop)->op_nextop, st);
        }
        if (check_new(st, cLOOPx(baseop)->op_lastop)) {
          total_size += op_size(aTHX_ cLOOPx(baseop)->op_lastop, st);
        }  

        TAG;break;
      case OPc_COP: TAG;
        {
          COP *basecop;
          basecop = (COP *)baseop;
          total_size += sizeof(struct cop);

          /* Change 33656 by nicholas@mouse-mill on 2008/04/07 11:29:51
          Eliminate cop_label from struct cop by storing a label as the first
          entry in the hints hash. Most statements don't have labels, so this
          will save memory. Not sure how much. 
          The check below will be incorrect fail on bleadperls
          before 5.11 @33656, but later than 5.10, producing slightly too
          small memory sizes on these Perls. */
#if (PERL_VERSION < 11)
          if (check_new(st, basecop->cop_label)) {
        total_size += strlen(basecop->cop_label);
          }
#endif
#ifdef USE_ITHREADS
          if (check_new(st, basecop->cop_file)) {
        total_size += strlen(basecop->cop_file);
          }
          if (check_new(st, basecop->cop_stashpv)) {
        total_size += strlen(basecop->cop_stashpv);
          }
#else
          if (check_new(st, basecop->cop_stash)) {
        total_size += thing_size(aTHX_ (SV *)basecop->cop_stash, st);
          }
          if (check_new(st, basecop->cop_filegv)) {
        total_size += thing_size(aTHX_ (SV *)basecop->cop_filegv, st);
          }
#endif

        }
        TAG;break;
      default:
        TAG;break;
      }
  }
  CAUGHT_EXCEPTION {
      if (st->dangle_whine) 
          warn( "Devel::Size: Encountered dangling pointer in opcode at: %p\n", baseop );
  }
  return total_size;
}

#if PERL_VERSION > 9 || (PERL_VERSION == 9 && PERL_SUBVERSION > 2)
#  define NEW_HEAD_LAYOUT
#endif

static UV
thing_size(pTHX_ const SV * const orig_thing, struct state *st) {
  const SV *thing = orig_thing;
  UV total_size = sizeof(SV);

  switch (SvTYPE(thing)) {
    /* Is it undef? */
  case SVt_NULL: TAG;
    TAG;break;
    /* Just a plain integer. This will be differently sized depending
       on whether purify's been compiled in */
  case SVt_IV: TAG;
#ifndef NEW_HEAD_LAYOUT
#  ifdef PURIFY
    total_size += sizeof(sizeof(XPVIV));
#  else
    total_size += sizeof(IV);
#  endif
#endif
    TAG;break;
    /* Is it a float? Like the int, it depends on purify */
  case SVt_NV: TAG;
#ifdef PURIFY
    total_size += sizeof(sizeof(XPVNV));
#else
    total_size += sizeof(NV);
#endif
    TAG;break;
#if (PERL_VERSION < 11)     
    /* Is it a reference? */
  case SVt_RV: TAG;
#ifndef NEW_HEAD_LAYOUT
    total_size += sizeof(XRV);
#endif
    TAG;break;
#endif
    /* How about a plain string? In which case we need to add in how
       much has been allocated */
  case SVt_PV: TAG;
    total_size += sizeof(XPV);
#if (PERL_VERSION < 11)
    total_size += SvROK(thing) ? thing_size(aTHX_ SvRV(thing), st) : SvLEN(thing);
#else
    total_size += SvLEN(thing);
#endif
    TAG;break;
    /* A string with an integer part? */
  case SVt_PVIV: TAG;
    total_size += sizeof(XPVIV);
#if (PERL_VERSION < 11)
    total_size += SvROK(thing) ? thing_size(aTHX_ SvRV(thing), st) : SvLEN(thing);
#else
    total_size += SvLEN(thing);
#endif
    if(SvOOK(thing)) {
        total_size += SvIVX(thing);
    }
    TAG;break;
    /* A scalar/string/reference with a float part? */
  case SVt_PVNV: TAG;
    total_size += sizeof(XPVNV);
#if (PERL_VERSION < 11)
    total_size += SvROK(thing) ? thing_size(aTHX_ SvRV(thing), st) : SvLEN(thing);
#else
    total_size += SvLEN(thing);
#endif
    TAG;break;
  case SVt_PVMG: TAG;
    total_size += sizeof(XPVMG);
#if (PERL_VERSION < 11)
    total_size += SvROK(thing) ? thing_size(aTHX_ SvRV(thing), st) : SvLEN(thing);
#else
    total_size += SvLEN(thing);
#endif
    total_size += magic_size(thing, st);
    TAG;break;
#if PERL_VERSION <= 8
  case SVt_PVBM: TAG;
    total_size += sizeof(XPVBM);
#if (PERL_VERSION < 11)
    total_size += SvROK(thing) ? thing_size(aTHX_ SvRV(thing), st) : SvLEN(thing);
#else
    total_size += SvLEN(thing);
#endif
    total_size += magic_size(thing, st);
    TAG;break;
#endif
  case SVt_PVLV: TAG;
    total_size += sizeof(XPVLV);
#if (PERL_VERSION < 11)
    total_size += SvROK(thing) ? thing_size(aTHX_ SvRV(thing), st) : SvLEN(thing);
#else
    total_size += SvLEN(thing);
#endif
    total_size += magic_size(thing, st);
    TAG;break;
    /* How much space is dedicated to the array? Not counting the
       elements in the array, mind, just the array itself */
  case SVt_PVAV: TAG;
    total_size += sizeof(XPVAV);
    /* Is there anything in the array? */
    if (AvMAX(thing) != -1) {
      /* an array with 10 slots has AvMax() set to 9 - te 2007-04-22 */
      total_size += sizeof(SV *) * (AvMAX(thing) + 1);
      dbg_printf(("total_size: %li AvMAX: %li av_len: $i\n", total_size, AvMAX(thing), av_len((AV*)thing)));
    }
    /* Add in the bits on the other side of the beginning */

    dbg_printf(("total_size %li, sizeof(SV *) %li, AvARRAY(thing) %li, AvALLOC(thing)%li , sizeof(ptr) %li \n", 
    total_size, sizeof(SV*), AvARRAY(thing), AvALLOC(thing), sizeof( thing )));

    /* under Perl 5.8.8 64bit threading, AvARRAY(thing) was a pointer while AvALLOC was 0,
       resulting in grossly overstated sized for arrays. Technically, this shouldn't happen... */
    if (AvALLOC(thing) != 0) {
      total_size += (sizeof(SV *) * (AvARRAY(thing) - AvALLOC(thing)));
      }
#if (PERL_VERSION < 9)
    /* Is there something hanging off the arylen element?
       Post 5.9.something this is stored in magic, so will be found there,
       and Perl_av_arylen_p() takes a non-const AV*, hence compilers rightly
       complain about AvARYLEN() passing thing to it.  */
    if (AvARYLEN(thing)) {
      if (check_new(st, AvARYLEN(thing))) {
    total_size += thing_size(aTHX_ AvARYLEN(thing), st);
      }
    }
#endif
    total_size += magic_size(thing, st);
    TAG;break;
  case SVt_PVHV: TAG;
    /* First the base struct */
    total_size += sizeof(XPVHV);
    /* Now the array of buckets */
    total_size += (sizeof(HE *) * (HvMAX(thing) + 1));
    /* Now walk the bucket chain */
    if (HvARRAY(thing)) {
      HE *cur_entry;
      UV cur_bucket = 0;
      for (cur_bucket = 0; cur_bucket <= HvMAX(thing); cur_bucket++) {
        cur_entry = *(HvARRAY(thing) + cur_bucket);
        while (cur_entry) {
          total_size += sizeof(HE);
          if (cur_entry->hent_hek) {
            /* Hash keys can be shared. Have we seen this before? */
            if (check_new(st, cur_entry->hent_hek)) {
              total_size += HEK_BASESIZE + cur_entry->hent_hek->hek_len + 2;
            }
          }
          cur_entry = cur_entry->hent_next;
        }
      }
    }
    total_size += magic_size(thing, st);
    TAG;break;
  case SVt_PVCV: TAG;
    total_size += sizeof(XPVCV);
    total_size += magic_size(thing, st);

    total_size += ((XPVIO *) SvANY(thing))->xpv_len;
    if (check_new(st, CvSTASH(thing))) {
      total_size += thing_size(aTHX_ (SV *)CvSTASH(thing), st);
    }
    if (check_new(st, SvSTASH(thing))) {
      total_size += thing_size(aTHX_ (SV *)SvSTASH(thing), st);
    }
    if (check_new(st, CvGV(thing))) {
      total_size += thing_size(aTHX_ (SV *)CvGV(thing), st);
    }
    if (check_new(st, CvPADLIST(thing))) {
      total_size += thing_size(aTHX_ (SV *)CvPADLIST(thing), st);
    }
    if (check_new(st, CvOUTSIDE(thing))) {
      total_size += thing_size(aTHX_ (SV *)CvOUTSIDE(thing), st);
    }
    if (CvISXSUB(thing)) {
	SV *sv = cv_const_sv((CV *)thing);
	if (sv) {
	    total_size += thing_size(aTHX_ sv, st);
	}
    } else {
	if (check_new(st, CvSTART(thing))) {
	    total_size += op_size(aTHX_ CvSTART(thing), st);
	}
	if (check_new(st, CvROOT(thing))) {
	    total_size += op_size(aTHX_ CvROOT(thing), st);
	}
    }

    TAG;break;
  case SVt_PVGV: TAG;
    total_size += magic_size(thing, st);
    total_size += sizeof(XPVGV);
    total_size += GvNAMELEN(thing);
#ifdef GvFILE
    /* Is there a file? */
    if (GvFILE(thing)) {
      if (check_new(st, GvFILE(thing))) {
    total_size += strlen(GvFILE(thing));
      }
    }
#endif
    /* Is there something hanging off the glob? */
    if (GvGP(thing)) {
      if (check_new(st, GvGP(thing))) {
    total_size += sizeof(GP);
    {
      SV *generic_thing;
      if ((generic_thing = (SV *)(GvGP(thing)->gp_sv))) {
        total_size += thing_size(aTHX_ generic_thing, st);
      }
      if ((generic_thing = (SV *)(GvGP(thing)->gp_form))) {
        total_size += thing_size(aTHX_ generic_thing, st);
      }
      if ((generic_thing = (SV *)(GvGP(thing)->gp_av))) {
        total_size += thing_size(aTHX_ generic_thing, st);
      }
      if ((generic_thing = (SV *)(GvGP(thing)->gp_hv))) {
        total_size += thing_size(aTHX_ generic_thing, st);
      }
      if ((generic_thing = (SV *)(GvGP(thing)->gp_egv))) {
        total_size += thing_size(aTHX_ generic_thing, st);
      }
      if ((generic_thing = (SV *)(GvGP(thing)->gp_cv))) {
        total_size += thing_size(aTHX_ generic_thing, st);
      }
    }
      }
    }
    TAG;break;
  case SVt_PVFM: TAG;
    total_size += sizeof(XPVFM);
    total_size += magic_size(thing, st);
    total_size += ((XPVIO *) SvANY(thing))->xpv_len;
    if (check_new(st, CvPADLIST(thing))) {
      total_size += thing_size(aTHX_ (SV *)CvPADLIST(thing), st);
    }
    if (check_new(st, CvOUTSIDE(thing))) {
      total_size += thing_size(aTHX_ (SV *)CvOUTSIDE(thing), st);
    }

    if (st->go_yell && !st->fm_whine) {
      carp("Devel::Size: Calculated sizes for FMs are incomplete");
      st->fm_whine = 1;
    }
    TAG;break;
  case SVt_PVIO: TAG;
    total_size += sizeof(XPVIO);
    total_size += magic_size(thing, st);
    if (check_new(st, (SvPVX_const(thing)))) {
      total_size += ((XPVIO *) SvANY(thing))->xpv_cur;
    }
    /* Some embedded char pointers */
    if (check_new(st, ((XPVIO *) SvANY(thing))->xio_top_name)) {
      total_size += strlen(((XPVIO *) SvANY(thing))->xio_top_name);
    }
    if (check_new(st, ((XPVIO *) SvANY(thing))->xio_fmt_name)) {
      total_size += strlen(((XPVIO *) SvANY(thing))->xio_fmt_name);
    }
    if (check_new(st, ((XPVIO *) SvANY(thing))->xio_bottom_name)) {
      total_size += strlen(((XPVIO *) SvANY(thing))->xio_bottom_name);
    }
    /* Throw the GVs on the list to be walked if they're not-null */
    if (((XPVIO *) SvANY(thing))->xio_top_gv) {
      total_size += thing_size(aTHX_ (SV *)((XPVIO *) SvANY(thing))->xio_top_gv, 
                   st);
    }
    if (((XPVIO *) SvANY(thing))->xio_bottom_gv) {
      total_size += thing_size(aTHX_ (SV *)((XPVIO *) SvANY(thing))->xio_bottom_gv, 
                   st);
    }
    if (((XPVIO *) SvANY(thing))->xio_fmt_gv) {
      total_size += thing_size(aTHX_ (SV *)((XPVIO *) SvANY(thing))->xio_fmt_gv, 
                   st);
    }

    /* Only go trotting through the IO structures if they're really
       trottable. If USE_PERLIO is defined we can do this. If
       not... we can't, so we don't even try */
#ifdef USE_PERLIO
    /* Dig into xio_ifp and xio_ofp here */
    warn("Devel::Size: Can't size up perlio layers yet\n");
#endif
    TAG;break;
  default:
    warn("Devel::Size: Unknown variable type: %d encountered\n", SvTYPE(thing) );
  }
  return total_size;
}

static struct state *
new_state(pTHX)
{
    SV *warn_flag;
    struct state *st;
    Newxz(st, 1, struct state);
    st->go_yell = TRUE;
    if (NULL != (warn_flag = perl_get_sv("Devel::Size::warn", FALSE))) {
	st->dangle_whine = st->go_yell = SvIV(warn_flag) ? TRUE : FALSE;
    }
    if (NULL != (warn_flag = perl_get_sv("Devel::Size::dangle", FALSE))) {
	st->dangle_whine = SvIV(warn_flag) ? TRUE : FALSE;
    }
    return st;
}

MODULE = Devel::Size        PACKAGE = Devel::Size       

PROTOTYPES: DISABLE

IV
size(orig_thing)
     SV *orig_thing
CODE:
{
  SV *thing = orig_thing;
  struct state *st = new_state(aTHX);
  
  /* If they passed us a reference then dereference it. This is the
     only way we can check the sizes of arrays and hashes */
#if (PERL_VERSION < 11)
  if (SvOK(thing) && SvROK(thing)) {
    thing = SvRV(thing);
  }
#else
  if (SvROK(thing)) {
    thing = SvRV(thing);
  }
#endif

  RETVAL = thing_size(aTHX_ thing, st);
  free_state(st);
}
OUTPUT:
  RETVAL


IV
total_size(orig_thing)
       SV *orig_thing
CODE:
{
  SV *thing = orig_thing;
  /* Array with things we still need to do */
  AV *pending_array;
  IV size = 0;
  struct state *st = new_state(aTHX);

  /* Size starts at zero */
  RETVAL = 0;

  pending_array = newAV();

  /* We cannot push HV/AV directly, only the RV. So deref it
     later (see below for "*** dereference later") and adjust here for
     the miscalculation.
     This is the only way we can check the sizes of arrays and hashes. */
  if (SvROK(thing)) {
      RETVAL -= thing_size(aTHX_ thing, NULL);
  } 

  /* Put it on the pending array */
  av_push(pending_array, thing);

  /* Now just yank things off the end of the array until it's done */
  while (av_len(pending_array) >= 0) {
    thing = av_pop(pending_array);
    /* Process it if we've not seen it */
    if (check_new(st, thing)) {
      dbg_printf(("# Found type %i at %p\n", SvTYPE(thing), thing));
      /* Is it valid? */
      if (thing) {
    /* Yes, it is. So let's check the type */
    switch (SvTYPE(thing)) {
    /* fix for bug #24846 (Does not correctly recurse into references in a PVNV-type scalar) */
    case SVt_PVNV: TAG;
      if (SvROK(thing))
        {
        av_push(pending_array, SvRV(thing));
        } 
      TAG;break;

    /* this is the "*** dereference later" part - see above */
#if (PERL_VERSION < 11)
        case SVt_RV: TAG;
#else
        case SVt_IV: TAG;
#endif
             dbg_printf(("# Found RV\n"));
          if (SvROK(thing)) {
             dbg_printf(("# Found RV\n"));
             av_push(pending_array, SvRV(thing));
          }
          TAG;break;

    case SVt_PVAV: TAG;
      {
        AV *tempAV = (AV *)thing;
        SV **tempSV;

        dbg_printf(("# Found type AV\n"));
        /* Quick alias to cut down on casting */
        
        /* Any elements? */
        if (av_len(tempAV) != -1) {
          IV index;
          /* Run through them all */
          for (index = 0; index <= av_len(tempAV); index++) {
        /* Did we get something? */
        if ((tempSV = av_fetch(tempAV, index, 0))) {
          /* Was it undef? */
          if (*tempSV != &PL_sv_undef) {
            /* Apparently not. Save it for later */
            av_push(pending_array, *tempSV);
          }
        }
          }
        }
      }
      TAG;break;

    case SVt_PVHV: TAG;
      dbg_printf(("# Found type HV\n"));
      /* Is there anything in here? */
      if (hv_iterinit((HV *)thing)) {
        HE *temp_he;
        while ((temp_he = hv_iternext((HV *)thing))) {
          av_push(pending_array, hv_iterval((HV *)thing, temp_he));
        }
      }
      TAG;break;
     
    case SVt_PVGV: TAG;
      dbg_printf(("# Found type GV\n"));
      /* Run through all the pieces and push the ones with bits */
      if (GvSV(thing)) {
        av_push(pending_array, (SV *)GvSV(thing));
      }
      if (GvFORM(thing)) {
        av_push(pending_array, (SV *)GvFORM(thing));
      }
      if (GvAV(thing)) {
        av_push(pending_array, (SV *)GvAV(thing));
      }
      if (GvHV(thing)) {
        av_push(pending_array, (SV *)GvHV(thing));
      }
      if (GvCV(thing)) {
        av_push(pending_array, (SV *)GvCV(thing));
      }
      TAG;break;
    default:
      TAG;break;
    }
      }
      
      size = thing_size(aTHX_ thing, st);
      RETVAL += size;
    } else {
    /* check_new() returned false: */
#ifdef DEVEL_SIZE_DEBUGGING
       if (SvOK(sv)) printf("# Ignore ref copy 0x%x\n", sv);
       else printf("# Ignore non-sv 0x%x\n", sv);
#endif
    }
  } /* end while */

  free_state(st);
  SvREFCNT_dec(pending_array);
}
OUTPUT:
  RETVAL

