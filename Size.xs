#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#if !defined(NV)
#define NV double
#endif

UV thing_size(SV *orig_thing) {
  SV *thing = orig_thing;
  UV total_size = sizeof(SV);
  
  /* If they passed us a reference then dereference it. This is the
     only way we can check the sizes of arrays and hashes */
  if (SvOK(thing) && SvROK(thing)) {
    thing = SvRV(thing);
  }
  
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
    break;
  case SVt_PVBM:
    croak("Not yet");
    break;
  case SVt_PVLV:
    croak("Not yet");
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
      total_size += thing_size(AvARYLEN(thing));
    }
    break;
  case SVt_PVHV:
    /* First the base struct */
    total_size += sizeof(XPVHV);
    /* Now the array of buckets */
    total_size += (sizeof(HE *) * (HvMAX(thing) + 1));
    /* Now walk the bucket chain */
    {
      HE *cur_entry;
      IV cur_bucket = 0;
      for (cur_bucket = 0; cur_bucket <= HvMAX(thing); cur_bucket++) {
	cur_entry = *(HvARRAY(thing) + cur_bucket);
	while (cur_entry) {
	  total_size += sizeof(HE);
	  if (cur_entry->hent_hek) {
	    total_size += sizeof(HEK);
	    total_size += cur_entry->hent_hek->hek_len - 1;
	  }
	  cur_entry = cur_entry->hent_next;
	}
      }
    }
    break;
  case SVt_PVCV:
    croak("Not yet");
    break;
  case SVt_PVGV:
    croak("Not yet");
    break;
  case SVt_PVFM:
    croak("Not yet");
    break;
  case SVt_PVIO:
    croak("Not yet");
    break;
  default:
    croak("Unknown variable type");
  }
  return total_size;
}


MODULE = Devel::Size		PACKAGE = Devel::Size		

IV
size(orig_thing)
     SV *orig_thing
CODE:
{
  RETVAL = thing_size(orig_thing);
}
OUTPUT:
  RETVAL
