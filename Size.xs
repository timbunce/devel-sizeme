#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define carp puts

#if !defined(NV)
#define NV double
#endif

/* Checks to see if thing is in the hash. Returns true or false, and
   notes thing in the hash.

   This code does one Evil Thing. Since we're tracking pointers, we
   tell perl that the string key is the address in the pointer. We do this by
   passing in the address of the address, along with the size of a
   pointer as the length. Perl then uses the four (or eight, on
   64-bit machines) bytes of the address as the string we're using as
   the key */
IV check_new(HV *tracking_hash, void *thing) {
  if (hv_exists(tracking_hash, (char *)&thing, sizeof(void *))) {
    return FALSE;
  }
  hv_store(tracking_hash, (char *)&thing, sizeof(void *), &PL_sv_undef, 0);
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
#ifdef PURIFY
    total_size += sizeof(sizeof(XPVIV));
#else
    total_size += sizeof(IV);
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
    total_size += sizeof(XRV);
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
  case SVt_PVBM:
    total_size += sizeof(XPVBM);
    total_size += SvLEN(thing);
    total_size += magic_size(thing, tracking_hash);
    break;
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
    total_size += (sizeof(SV *) * (AvARRAY(thing) - AvALLOC(thing)));
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
	      total_size += sizeof(HEK);
	      total_size += cur_entry->hent_hek->hek_len - 1;
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
    carp("CV isn't complete");
    break;
  case SVt_PVGV:
    total_size += magic_size(thing, tracking_hash);
    total_size += sizeof(XPVGV);
    total_size += GvNAMELEN(thing);
    /* Is there a file? */
    if (GvFILE(thing)) {
      if (check_new(tracking_hash, GvFILE(thing))) {
	total_size += strlen(GvFILE(thing));
      }
    }
    /* Is there something hanging off the glob? */
    if (GvGP(thing)) {
      if (check_new(tracking_hash, GvGP(thing))) {
	total_size += sizeof(GP);
      }
    }
    break;
  case SVt_PVFM:
    total_size += sizeof(XPVFM);
    carp("FM isn't complete");
    break;
  case SVt_PVIO:
    total_size += sizeof(XPVIO);
    carp("IO isn't complete");
    break;
  default:
    croak("Unknown variable type");
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

  /* Size starts at zero */
  RETVAL = 0;

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
		if (tempSV = av_fetch(tempAV, index, 0)) {
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
	    while (temp_he = hv_iternext((HV *)thing)) {
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

      RETVAL += thing_size(thing, tracking_hash);
    }
  }
  
  /* Clean up after ourselves */
  SvREFCNT_dec(tracking_hash);
  SvREFCNT_dec(pending_array);
}
OUTPUT:
  RETVAL

