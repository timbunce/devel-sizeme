#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static int regex_whine;
static int fm_whine;


#define carp puts
UV thing_size(SV *, HV *);
typedef enum {
    OPc_NULL,	/* 0 */
    OPc_BASEOP,	/* 1 */
    OPc_UNOP,	/* 2 */
    OPc_BINOP,	/* 3 */
    OPc_LOGOP,	/* 4 */
    OPc_LISTOP,	/* 5 */
    OPc_PMOP,	/* 6 */
    OPc_SVOP,	/* 7 */
    OPc_PADOP,	/* 8 */
    OPc_PVOP,	/* 9 */
    OPc_LOOP,	/* 10 */
    OPc_COP	/* 11 */
} opclass;

static opclass
cc_opclass(OP *o)
{
    if (!o)
	return OPc_NULL;

    if (o->op_type == 0)
	return (o->op_flags & OPf_KIDS) ? OPc_UNOP : OPc_BASEOP;

    if (o->op_type == OP_SASSIGN)
	return ((o->op_private & OPpASSIGN_BACKWARDS) ? OPc_UNOP : OPc_BINOP);

#ifdef USE_ITHREADS
    if (o->op_type == OP_GV || o->op_type == OP_GVSV || o->op_type == OP_AELEMFAST)
	return OPc_PADOP;
#endif

    if ((o->op_type = OP_TRANS)) {
      return OPc_BASEOP;
    }

    switch (PL_opargs[o->op_type] & OA_CLASS_MASK) {
    case OA_BASEOP:
	return OPc_BASEOP;

    case OA_UNOP:
	return OPc_UNOP;

    case OA_BINOP:
	return OPc_BINOP;

    case OA_LOGOP:
	return OPc_LOGOP;

    case OA_LISTOP:
	return OPc_LISTOP;

    case OA_PMOP:
	return OPc_PMOP;

    case OA_SVOP:
	return OPc_SVOP;

    case OA_PADOP:
	return OPc_PADOP;

    case OA_PVOP_OR_SVOP:
        /*
         * Character translations (tr///) are usually a PVOP, keeping a 
         * pointer to a table of shorts used to look up translations.
         * Under utf8, however, a simple table isn't practical; instead,
         * the OP is an SVOP, and the SV is a reference to a swash
         * (i.e., an RV pointing to an HV).
         */
	return (o->op_private & (OPpTRANS_TO_UTF|OPpTRANS_FROM_UTF))
		? OPc_SVOP : OPc_PVOP;

    case OA_LOOP:
	return OPc_LOOP;

    case OA_COP:
	return OPc_COP;

    case OA_BASEOP_OR_UNOP:
	/*
	 * UNI(OP_foo) in toke.c returns token UNI or FUNC1 depending on
	 * whether parens were seen. perly.y uses OPf_SPECIAL to
	 * signal whether a BASEOP had empty parens or none.
	 * Some other UNOPs are created later, though, so the best
	 * test is OPf_KIDS, which is set in newUNOP.
	 */
	return (o->op_flags & OPf_KIDS) ? OPc_UNOP : OPc_BASEOP;

    case OA_FILESTATOP:
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
    case OA_LOOPEXOP:
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
    warn("can't determine class of operator %s, assuming BASEOP\n",
	 PL_op_name[o->op_type]);
    return OPc_BASEOP;
}


#if !defined(NV)
#define NV double
#endif

static int go_yell = 1;

/* Checks to see if thing is in the hash. Returns true or false, and
   notes thing in the hash.

   This code does one Evil Thing. Since we're tracking pointers, we
   tell perl that the string key is the address in the pointer. We do this by
   passing in the address of the address, along with the size of a
   pointer as the length. Perl then uses the four (or eight, on
   64-bit machines) bytes of the address as the string we're using as
   the key */
IV check_new(HV *tracking_hash, const void *thing) {
  if (NULL == thing) {
    return FALSE;
  }
  if (hv_exists(tracking_hash, (char *)&thing, sizeof(void *))) {
    return FALSE;
  }
  hv_store(tracking_hash, (char *)&thing, sizeof(void *), &PL_sv_yes, 0);
  return TRUE;

}

/* Figure out how much magic is attached to the SV and return the
   size */
IV magic_size(SV *thing, HV *tracking_hash) {
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
  while (magic_pointer && check_new(tracking_hash, magic_pointer)) {
    total_size += sizeof(MAGIC);

    /* Have we seen the magic vtable? */
    if (magic_pointer->mg_virtual &&
	check_new(tracking_hash, magic_pointer->mg_virtual)) {
      total_size += sizeof(MGVTBL);
    }

    /* Get the next in the chain */
    magic_pointer = magic_pointer->mg_moremagic;
  }

  return total_size;
}

UV regex_size(REGEXP *baseregex, HV *tracking_hash) {
  UV total_size = 0;

  total_size += sizeof(REGEXP);
  /* Note hte size of the paren offset thing */
  total_size += sizeof(I32) * baseregex->nparens * 2;
  total_size += strlen(baseregex->precomp);

  if (go_yell && !regex_whine) {
    carp("Devel::Size: Calculated sizes for compiled regexes are incomple, and probably always will be");
    regex_whine = 1;
  }

  return total_size;
}

UV op_size(OP *baseop, HV *tracking_hash) {
  UV total_size = 0;

  if (check_new(tracking_hash, baseop->op_next)) {
    total_size += op_size(baseop->op_next, tracking_hash);
  }
  if (check_new(tracking_hash, baseop->op_next)) {
    total_size += op_size(baseop->op_next, tracking_hash);
  }

  switch (cc_opclass(baseop)) {
  case OPc_BASEOP:
    total_size += sizeof(struct op);
    break;
  case OPc_UNOP:
    total_size += sizeof(struct unop);
    if (check_new(tracking_hash, cUNOPx(baseop)->op_first)) {
      total_size += op_size(cUNOPx(baseop)->op_first, tracking_hash);
    }
    break;
  case OPc_BINOP:
    total_size += sizeof(struct binop);
    if (check_new(tracking_hash, cBINOPx(baseop)->op_first)) {
      total_size += op_size(cBINOPx(baseop)->op_first, tracking_hash);
    }  
    if (check_new(tracking_hash, cBINOPx(baseop)->op_last)) {
      total_size += op_size(cBINOPx(baseop)->op_last, tracking_hash);
    }
    break;
  case OPc_LOGOP:
    total_size += sizeof(struct logop);
    if (check_new(tracking_hash, cLOGOPx(baseop)->op_first)) {
      total_size += op_size(cBINOPx(baseop)->op_first, tracking_hash);
    }  
    if (check_new(tracking_hash, cLOGOPx(baseop)->op_other)) {
      total_size += op_size(cLOGOPx(baseop)->op_other, tracking_hash);
    }
    break;
  case OPc_LISTOP:
    total_size += sizeof(struct listop);
    if (check_new(tracking_hash, cLISTOPx(baseop)->op_first)) {
      total_size += op_size(cLISTOPx(baseop)->op_first, tracking_hash);
    }  
    if (check_new(tracking_hash, cLISTOPx(baseop)->op_last)) {
      total_size += op_size(cLISTOPx(baseop)->op_last, tracking_hash);
    }
    break;
  case OPc_PMOP:
    total_size += sizeof(struct pmop);
    if (check_new(tracking_hash, cPMOPx(baseop)->op_first)) {
      total_size += op_size(cPMOPx(baseop)->op_first, tracking_hash);
    }  
    if (check_new(tracking_hash, cPMOPx(baseop)->op_last)) {
      total_size += op_size(cPMOPx(baseop)->op_last, tracking_hash);
    }
    if (check_new(tracking_hash, cPMOPx(baseop)->op_pmreplroot)) {
      total_size += op_size(cPMOPx(baseop)->op_pmreplroot, tracking_hash);
    }
    if (check_new(tracking_hash, cPMOPx(baseop)->op_pmreplstart)) {
      total_size += op_size(cPMOPx(baseop)->op_pmreplstart, tracking_hash);
    }
    if (check_new(tracking_hash, cPMOPx(baseop)->op_pmnext)) {
      total_size += op_size((OP *)cPMOPx(baseop)->op_pmnext, tracking_hash);
    }
    /* This is defined away in perl 5.8.x, but it is in there for
       5.6.x */
#ifdef PM_GETRE
    if (check_new(tracking_hash, PM_GETRE((cPMOPx(baseop))))) {
      total_size += regex_size(PM_GETRE(cPMOPx(baseop)), tracking_hash);
    }
#else
    if (check_new(tracking_hash, cPMOPx(baseop)->op_pmregexp)) {
      total_size += regex_size(cPMOPx(baseop)->op_pmregexp, tracking_hash);
    }
#endif
    break;
  case OPc_SVOP:
    total_size += sizeof(struct pmop);
    if (check_new(tracking_hash, cSVOPx(baseop)->op_sv)) {
      total_size += thing_size(cSVOPx(baseop)->op_sv, tracking_hash);
    }
    break;
  case OPc_PADOP:
    total_size += sizeof(struct padop);
    break;
  case OPc_PVOP:
    if (check_new(tracking_hash, cPVOPx(baseop)->op_pv)) {
      total_size += strlen(cPVOPx(baseop)->op_pv);
    }
  case OPc_LOOP:
    total_size += sizeof(struct loop);
    if (check_new(tracking_hash, cLOOPx(baseop)->op_first)) {
      total_size += op_size(cLOOPx(baseop)->op_first, tracking_hash);
    }  
    if (check_new(tracking_hash, cLOOPx(baseop)->op_last)) {
      total_size += op_size(cLOOPx(baseop)->op_last, tracking_hash);
    }
    if (check_new(tracking_hash, cLOOPx(baseop)->op_redoop)) {
      total_size += op_size(cLOOPx(baseop)->op_redoop, tracking_hash);
    }  
    if (check_new(tracking_hash, cLOOPx(baseop)->op_nextop)) {
      total_size += op_size(cLOOPx(baseop)->op_nextop, tracking_hash);
    }
    /* Not working for some reason, but the code's here for later
       fixing 
    if (check_new(tracking_hash, cLOOPx(baseop)->op_lastop)) {
      total_size += op_size(cLOOPx(baseop)->op_lastop, tracking_hash);
    }  
    */
    break;
  case OPc_COP:
    {
      COP *basecop;
      basecop = (COP *)baseop;
      total_size += sizeof(struct cop);

      if (check_new(tracking_hash, basecop->cop_label)) {
	total_size += strlen(basecop->cop_label);
      }
#ifdef USE_ITHREADS
      if (check_new(tracking_hash, basecop->cop_file)) {
	total_size += strlen(basecop->cop_file);
      }
      if (check_new(tracking_hash, basecop->cop_stashpv)) {
	total_size += strlen(basecop->cop_stashpv);
      }
#else
      if (check_new(tracking_hash, basecop->cop_stash)) {
	total_size += thing_size((SV *)basecop->cop_stash, tracking_hash);
      }
      if (check_new(tracking_hash, basecop->cop_filegv)) {
	total_size += thing_size((SV *)basecop->cop_filegv, tracking_hash);
      }
#endif

    }
    break;
  default:
    break;
  }
  return total_size;
}

#if PERL_VERSION > 9 || (PERL_VERSION == 9 && PERL_SUBVERSION > 2)
#  define NEW_HEAD_LAYOUT
#endif

UV thing_size(SV *orig_thing, HV *tracking_hash) {
  SV *thing = orig_thing;
  UV total_size = sizeof(SV);
  
  switch (SvTYPE(thing)) {
    /* Is it undef? */
  case SVt_NULL:
    break;
    /* Just a plain integer. This will be differently sized depending
       on whether purify's been compiled in */
  case SVt_IV:
#ifndef NEW_HEAD_LAYOUT
#  ifdef PURIFY
    total_size += sizeof(sizeof(XPVIV));
#  else
    total_size += sizeof(IV);
#  endif
#endif
    break;
    /* Is it a float? Like the int, it depends on purify */
  case SVt_NV:
#ifdef PURIFY
    total_size += sizeof(sizeof(XPVNV));
#else
    total_size += sizeof(NV);
#endif
    break;
    /* Is it a reference? */
  case SVt_RV:
#ifndef NEW_HEAD_LAYOUT
    total_size += sizeof(XRV);
#endif
    break;
    /* How about a plain string? In which case we need to add in how
       much has been allocated */
  case SVt_PV:
    total_size += sizeof(XPV);
    total_size += SvLEN(thing);
    break;
    /* A string with an integer part? */
  case SVt_PVIV:
    total_size += sizeof(XPVIV);
    total_size += SvLEN(thing);
    if(SvOOK(thing)) {
        total_size += SvIVX(thing);
	}
    break;
    /* A string with a float part? */
  case SVt_PVNV:
    total_size += sizeof(XPVNV);
    total_size += SvLEN(thing);
    break;
  case SVt_PVMG:
    total_size += sizeof(XPVMG);
    total_size += SvLEN(thing);
    total_size += magic_size(thing, tracking_hash);
    break;
#if PERL_VERSION <= 8
  case SVt_PVBM:
    total_size += sizeof(XPVBM);
    total_size += SvLEN(thing);
    total_size += magic_size(thing, tracking_hash);
    break;
#endif
  case SVt_PVLV:
    total_size += sizeof(XPVLV);
    total_size += SvLEN(thing);
    total_size += magic_size(thing, tracking_hash);
    break;
    /* How much space is dedicated to the array? Not counting the
       elements in the array, mind, just the array itself */
  case SVt_PVAV:
    total_size += sizeof(XPVAV);
    /* Is there anything in the array? */
    if (AvMAX(thing) != -1) {
      total_size += sizeof(SV *) * AvMAX(thing);
    }
    /* Add in the bits on the other side of the beginning */

    /* 
      printf ("total_size %li, sizeof(SV *) %li, AvARRAY(thing) %li, AvALLOC(thing)%li , sizeof(ptr) %li \n", 
	total_size, sizeof(SV*), AvARRAY(thing), AvALLOC(thing), sizeof( thing )); */

    /* under Perl 5.8.8 64bit threading, AvARRAY(thing) was a pointer while AvALLOC was 0,
       resulting in grossly overstated sized for arrays */
    if (AvALLOC(thing) != 0) {
      total_size += (sizeof(SV *) * (AvARRAY(thing) - AvALLOC(thing)));
      }
    /* Is there something hanging off the arylen element? */
    if (AvARYLEN(thing)) {
      if (check_new(tracking_hash, AvARYLEN(thing))) {
	total_size += thing_size(AvARYLEN(thing), tracking_hash);
      }
    }
    total_size += magic_size(thing, tracking_hash);
    break;
  case SVt_PVHV:
    /* First the base struct */
    total_size += sizeof(XPVHV);
    /* Now the array of buckets */
    total_size += (sizeof(HE *) * (HvMAX(thing) + 1));
    /* Now walk the bucket chain */
    if (HvARRAY(thing)) {
      HE *cur_entry;
      IV cur_bucket = 0;
      for (cur_bucket = 0; cur_bucket <= HvMAX(thing); cur_bucket++) {
	cur_entry = *(HvARRAY(thing) + cur_bucket);
	while (cur_entry) {
	  total_size += sizeof(HE);
	  if (cur_entry->hent_hek) {
	    /* Hash keys can be shared. Have we seen this before? */
	    if (check_new(tracking_hash, cur_entry->hent_hek)) {
	      total_size += HEK_BASESIZE + cur_entry->hent_hek->hek_len + 2;
	    }
	  }
	  cur_entry = cur_entry->hent_next;
	}
      }
    }
    total_size += magic_size(thing, tracking_hash);
    break;
  case SVt_PVCV:
    total_size += sizeof(XPVCV);
    total_size += magic_size(thing, tracking_hash);

    total_size += ((XPVIO *) SvANY(thing))->xpv_len;
    if (check_new(tracking_hash, CvSTASH(thing))) {
      total_size += thing_size((SV *)CvSTASH(thing), tracking_hash);
    }
    if (check_new(tracking_hash, SvSTASH(thing))) {
      total_size += thing_size((SV *)SvSTASH(thing), tracking_hash);
    }
    if (check_new(tracking_hash, CvGV(thing))) {
      total_size += thing_size((SV *)CvGV(thing), tracking_hash);
    }
    if (check_new(tracking_hash, CvPADLIST(thing))) {
      total_size += thing_size((SV *)CvPADLIST(thing), tracking_hash);
    }
    if (check_new(tracking_hash, CvOUTSIDE(thing))) {
      total_size += thing_size((SV *)CvOUTSIDE(thing), tracking_hash);
    }

    if (check_new(tracking_hash, CvSTART(thing))) {
      total_size += op_size(CvSTART(thing), tracking_hash);
    }
    if (check_new(tracking_hash, CvROOT(thing))) {
      total_size += op_size(CvROOT(thing), tracking_hash);
    }

    break;
  case SVt_PVGV:
    total_size += magic_size(thing, tracking_hash);
    total_size += sizeof(XPVGV);
    total_size += GvNAMELEN(thing);
#ifdef GvFILE
    /* Is there a file? */
    if (GvFILE(thing)) {
      if (check_new(tracking_hash, GvFILE(thing))) {
	total_size += strlen(GvFILE(thing));
      }
    }
#endif
    /* Is there something hanging off the glob? */
    if (GvGP(thing)) {
      if (check_new(tracking_hash, GvGP(thing))) {
	total_size += sizeof(GP);
	{
	  SV *generic_thing;
	  if ((generic_thing = (SV *)(GvGP(thing)->gp_sv))) {
	    total_size += thing_size(generic_thing, tracking_hash);
	  }
	  if ((generic_thing = (SV *)(GvGP(thing)->gp_form))) {
	    total_size += thing_size(generic_thing, tracking_hash);
	  }
	  if ((generic_thing = (SV *)(GvGP(thing)->gp_av))) {
	    total_size += thing_size(generic_thing, tracking_hash);
	  }
	  if ((generic_thing = (SV *)(GvGP(thing)->gp_hv))) {
	    total_size += thing_size(generic_thing, tracking_hash);
	  }
	  if ((generic_thing = (SV *)(GvGP(thing)->gp_egv))) {
	    total_size += thing_size(generic_thing, tracking_hash);
	  }
	  if ((generic_thing = (SV *)(GvGP(thing)->gp_cv))) {
	    total_size += thing_size(generic_thing, tracking_hash);
	  }
	}
      }
    }
    break;
  case SVt_PVFM:
    total_size += sizeof(XPVFM);
    total_size += magic_size(thing, tracking_hash);
    total_size += ((XPVIO *) SvANY(thing))->xpv_len;
    if (check_new(tracking_hash, CvPADLIST(thing))) {
      total_size += thing_size((SV *)CvPADLIST(thing), tracking_hash);
    }
    if (check_new(tracking_hash, CvOUTSIDE(thing))) {
      total_size += thing_size((SV *)CvOUTSIDE(thing), tracking_hash);
    }

    if (go_yell && !fm_whine) {
      carp("Devel::Size: Calculated sizes for FMs are incomplete");
      fm_whine = 1;
    }
    break;
  case SVt_PVIO:
    total_size += sizeof(XPVIO);
    total_size += magic_size(thing, tracking_hash);
    if (check_new(tracking_hash, (SvPVX(thing)))) {
      total_size += ((XPVIO *) SvANY(thing))->xpv_cur;
    }
    /* Some embedded char pointers */
    if (check_new(tracking_hash, ((XPVIO *) SvANY(thing))->xio_top_name)) {
      total_size += strlen(((XPVIO *) SvANY(thing))->xio_top_name);
    }
    if (check_new(tracking_hash, ((XPVIO *) SvANY(thing))->xio_fmt_name)) {
      total_size += strlen(((XPVIO *) SvANY(thing))->xio_fmt_name);
    }
    if (check_new(tracking_hash, ((XPVIO *) SvANY(thing))->xio_bottom_name)) {
      total_size += strlen(((XPVIO *) SvANY(thing))->xio_bottom_name);
    }
    /* Throw the GVs on the list to be walked if they're not-null */
    if (((XPVIO *) SvANY(thing))->xio_top_gv) {
      total_size += thing_size((SV *)((XPVIO *) SvANY(thing))->xio_top_gv, 
			       tracking_hash);
    }
    if (((XPVIO *) SvANY(thing))->xio_bottom_gv) {
      total_size += thing_size((SV *)((XPVIO *) SvANY(thing))->xio_bottom_gv, 
			       tracking_hash);
    }
    if (((XPVIO *) SvANY(thing))->xio_fmt_gv) {
      total_size += thing_size((SV *)((XPVIO *) SvANY(thing))->xio_fmt_gv, 
			       tracking_hash);
    }

    /* Only go trotting through the IO structures if they're really
       trottable. If USE_PERLIO is defined we can do this. If
       not... we can't, so we don't even try */
#ifdef USE_PERLIO
    /* Dig into xio_ifp and xio_ofp here */
    croak("Devel::Size: Can't size up perlio layers yet");
#endif
    break;
  default:
    croak("Devel::Size: Unknown variable type");
  }
  return total_size;
}

MODULE = Devel::Size		PACKAGE = Devel::Size		

PROTOTYPES: DISABLE

IV
size(orig_thing)
     SV *orig_thing
CODE:
{
  SV *thing = orig_thing;
  /* Hash to track our seen pointers */
  HV *tracking_hash = newHV();
  SV *warn_flag;

  /* Check warning status */
  go_yell = 0;
  regex_whine = 0;
  fm_whine = 0;

  if (NULL != (warn_flag = perl_get_sv("Devel::Size::warn", FALSE))) {
    go_yell = SvIV(warn_flag);
  }
  

  /* If they passed us a reference then dereference it. This is the
     only way we can check the sizes of arrays and hashes */
  if (SvOK(thing) && SvROK(thing)) {
    thing = SvRV(thing);
  }
  
  RETVAL = thing_size(thing, tracking_hash);
  /* Clean up after ourselves */
  SvREFCNT_dec(tracking_hash);
}
OUTPUT:
  RETVAL


IV
total_size(orig_thing)
       SV *orig_thing
CODE:
{
  SV *thing = orig_thing;
  /* Hash to track our seen pointers */
  HV *tracking_hash = newHV();
  AV *pending_array = newAV();
  IV size = 0;
  SV *warn_flag;

  /* Size starts at zero */
  RETVAL = 0;

  /* Check warning status */
  go_yell = 0;
  regex_whine = 0;
  fm_whine = 0;

  if (NULL != (warn_flag = perl_get_sv("Devel::Size::warn", FALSE))) {
    go_yell = SvIV(warn_flag);
  }
  

  /* If they passed us a reference then dereference it. This is the
     only way we can check the sizes of arrays and hashes */
  if (SvOK(thing) && SvROK(thing)) {
    thing = SvRV(thing);
  }

  /* Put it on the pending array */
  av_push(pending_array, thing);

  /* Now just yank things off the end of the array until it's done */
  while (av_len(pending_array) >= 0) {
    thing = av_pop(pending_array);
    /* Process it if we've not seen it */
    if (check_new(tracking_hash, thing)) {
      /* Is it valid? */
      if (thing) {
	/* Yes, it is. So let's check the type */
	switch (SvTYPE(thing)) {
	case SVt_RV:
	  av_push(pending_array, SvRV(thing));
	  break;

	case SVt_PVAV:
	  {
	    /* Quick alias to cut down on casting */
	    AV *tempAV = (AV *)thing;
	    SV **tempSV;
	    
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
	  break;

	case SVt_PVHV:
	  /* Is there anything in here? */
	  if (hv_iterinit((HV *)thing)) {
	    HE *temp_he;
	    while ((temp_he = hv_iternext((HV *)thing))) {
	      av_push(pending_array, hv_iterval((HV *)thing, temp_he));
	    }
	  }
	  break;
	 
	case SVt_PVGV:
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
	  break;
	default:
	  break;
	}
      }

      
      size = thing_size(thing, tracking_hash);
      RETVAL += size;
    }
  }
  
  /* Clean up after ourselves */
  SvREFCNT_dec(tracking_hash);
  SvREFCNT_dec(pending_array);
}
OUTPUT:
  RETVAL

