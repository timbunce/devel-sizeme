/* -*- mode: C -*- */

#undef NDEBUG /* XXX */
#include <assert.h>

#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

/* Not yet in ppport.h */
#ifndef CvISXSUB
#  define CvISXSUB(cv)  (CvXSUB(cv) ? TRUE : FALSE)
#endif
#ifndef SvRV_const
#  define SvRV_const(rv) SvRV(rv)
#endif
#ifndef SvOOK_offset
#  define SvOOK_offset(sv, len) STMT_START { len = SvIVX(sv); } STMT_END
#endif
#ifndef SvIsCOW
#  define SvIsCOW(sv)           ((SvFLAGS(sv) & (SVf_FAKE | SVf_READONLY)) == \
                                    (SVf_FAKE | SVf_READONLY))
#endif
#ifndef SvIsCOW_shared_hash
#  define SvIsCOW_shared_hash(sv)   (SvIsCOW(sv) && SvLEN(sv) == 0)
#endif
#ifndef SvSHARED_HEK_FROM_PV
#  define SvSHARED_HEK_FROM_PV(pvx) \
        ((struct hek*)(pvx - STRUCT_OFFSET(struct hek, hek_key)))
#endif

#if PERL_VERSION < 6
#  define PL_opargs opargs
#  define PL_op_name op_name
#endif

#ifdef _MSC_VER 
/* "structured exception" handling is a Microsoft extension to C and C++.
   It's *not* C++ exception handling - C++ exception handling can't capture
   SEGVs and suchlike, whereas this can. There's no known analagous
    functionality on other platforms.  */
#  include <excpt.h>
#  define TRY_TO_CATCH_SEGV __try
#  define CAUGHT_EXCEPTION __except(EXCEPTION_EXECUTE_HANDLER)
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

#define BYTE_BITS    3
#define LEAF_BITS   (16 - BYTE_BITS)
#define LEAF_MASK   0x1FFF

typedef struct npath_node_st npath_node_t;
struct npath_node_st {
    npath_node_t *prev;
    const void *id;
    U8 type;
    U8 flags;
    UV seqn;
    U16 depth;
};

struct state {
    UV total_size;
    bool regex_whine;
    bool fm_whine;
    bool dangle_whine;
    bool go_yell;
    /* My hunch (not measured) is that for most architectures pointers will
       start with 0 bits, hence the start of this array will be hot, and the
       end unused. So put the flags next to the hot end.  */
    void *tracking[256];
    /* callback hooks and data */
    int (*add_attr_cb)(struct state *st, npath_node_t *npath_node, UV attr_type, const char *name, UV value);
    void (*free_state_cb)(struct state *st);
    UV seqn;
    void *state_cb_data; /* free'd by free_state() after free_state_cb() call */
};

#define ADD_SIZE(st, leafname, bytes) (NPathAddSizeCb(st, leafname, bytes) (st)->total_size += (bytes))

#define PATH_TRACKING
#ifdef PATH_TRACKING

#define NPathAddSizeCb(st, name, bytes) (st->add_attr_cb && st->add_attr_cb(st, NP-1, 0, (name), (bytes))),
#define pPATH npath_node_t *NPathArg

/* A subtle point here is that each dNPathSetNode leaves NP pointing to
 * the next unused slot (though with prev already filled in)
 * whereas NPathLink leaves NP unchanged, it just fills in the slot NP points
 * to and passes that NP value to the function being called.
 */
#define dNPathNodes(nodes, prev_np) \
            npath_node_t name_path_nodes[nodes+1]; /* +1 for NPathLink */ \
            npath_node_t *NP = &name_path_nodes[0]; \
            NP->seqn = 0; \
            NP->type = 0; \
            NP->id = "?0?"; /* DEBUG */ \
            NP->prev = prev_np
#define dNPathSetNode(nodeid, nodetype) \
            NP->id = nodeid; \
            NP->type = nodetype; \
            if(0)fprintf(stderr,"dNPathSetNode (%p <-) %p <- [%d %s]\n", NP->prev, NP, nodetype,(char*)nodeid);\
            NP++; \
            NP->id="?+?"; /* DEBUG */ \
            NP->seqn = 0; \
            NP->prev = (NP-1)

/* dNPathUseParent points NP directly the the parents' name_path_nodes array
 * So the function can only safely call ADD_*() but not NPathLink, unless the
 * caller has spare nodes in its name_path_nodes.
 */
#define dNPathUseParent(prev_np) npath_node_t *NP = (((prev_np+1)->prev = prev_np), prev_np+1)

#define NPtype_NAME     0x01
#define NPtype_LINK     0x02
#define NPtype_SV       0x03
#define NPtype_MAGIC    0x04
#define NPtype_OP       0x05

#define NPathLink(nodeid, nodetype)   ((NP->id = nodeid), (NP->type = nodetype), (NP->seqn = 0), NP)
#define NPathOpLink  (NPathArg)
#define ADD_ATTR(st, attr_type, attr_name, attr_value) (st->add_attr_cb && st->add_attr_cb(st, NP-1, attr_type, attr_name, attr_value))

#else

#define NPathAddSizeCb(st, name, bytes)
#define pPATH void *npath_dummy /* XXX ideally remove */
#define dNPathNodes(nodes, prev_np)  dNOOP
#define NPathLink(nodeid, nodetype)  NULL
#define NPathOpLink NULL
#define ADD_ATTR(st, attr_type, attr_name, attr_value) NOOP

#endif /* PATH_TRACKING */




#ifdef PATH_TRACKING

static const char *svtypenames[SVt_LAST] = {
#if PERL_VERSION < 9
  "NULL", "IV", "NV", "RV", "PV", "PVIV", "PVNV", "PVMG", "PVBM", "PVLV", "PVAV", "PVHV", "PVCV", "PVGV", "PVFM", "PVIO",
#elif PERL_VERSION == 10 && PERL_SUBVERSION == 0
  "NULL", "BIND", "IV", "NV", "RV", "PV", "PVIV", "PVNV", "PVMG", "PVGV", "PVLV", "PVAV", "PVHV", "PVCV", "PVFM", "PVIO",
#elif PERL_VERSION == 10 && PERL_SUBVERSION == 1
  "NULL", "BIND", "IV", "NV", "RV", "PV", "PVIV", "PVNV", "PVMG", "PVGV", "PVLV", "PVAV", "PVHV", "PVCV", "PVFM", "PVIO",
#elif PERL_VERSION < 13
  "NULL", "BIND", "IV", "NV", "PV", "PVIV", "PVNV", "PVMG", "REGEXP", "PVGV", "PVLV", "PVAV", "PVHV", "PVCV", "PVFM", "PVIO",
#else
  "NULL", "BIND", "IV", "NV", "PV", "PVIV", "PVNV", "PVMG", "REGEXP", "PVGV", "PVLV", "PVAV", "PVHV", "PVCV", "PVFM", "PVIO",
#endif
};

int
print_node_name(npath_node_t *npath_node)
{
    char buf[1024]; /* XXX */

    switch (npath_node->type) {
    case NPtype_SV: { /* id is pointer to the SV sv_size was called on */
        const SV *sv = (SV*)npath_node->id;
        int type = SvTYPE(sv);
        char *typename = (type == SVt_IV && SvROK(sv)) ? "RV" : svtypenames[type];
        fprintf(stderr, "SV(%s)", typename);
        switch(type) {  /* add some useful details */
        case SVt_PVAV: fprintf(stderr, " fill=%d/%ld", av_len((AV*)sv), AvMAX((AV*)sv)); break;
        case SVt_PVHV: fprintf(stderr, " fill=%ld/%ld", HvFILL((HV*)sv), HvMAX((HV*)sv)); break;
        }
        break;
    }
    case NPtype_OP: { /* id is pointer to the OP op_size was called on */
        const OP *op = (OP*)npath_node->id;
        fprintf(stderr, "OP(%s)", OP_NAME(op));
        break;
    }
    case NPtype_MAGIC: { /* id is pointer to the MAGIC struct */
        MAGIC *magic_pointer = (MAGIC*)npath_node->id;
        /* XXX it would be nice if we could reuse mg_names.c [sigh] */
        fprintf(stderr, "MAGIC(%c)", magic_pointer->mg_type ? magic_pointer->mg_type : '0');
        break;
    }
    case NPtype_LINK:
        fprintf(stderr, "%s->", npath_node->id);
        break;
    case NPtype_NAME:
        fprintf(stderr, "%s", npath_node->id);
        break;
    default:    /* assume id is a string pointer */
        fprintf(stderr, "UNKNOWN(%d,%p)", npath_node->type, npath_node->id);
        break;
    }
    return 0;
}

void
print_indent(int depth) {
    while (depth-- > 0)
        fprintf(stderr, ":   ");
}

int
print_formatted_node(struct state *st, npath_node_t *npath_node) {
    print_indent(npath_node->depth);
    print_node_name(npath_node);
    fprintf(stderr, "\t\t[#%ld @%u] ", npath_node->seqn, npath_node->depth);
    fprintf(stderr, "\n");
    return 0;
}

void
walk_new_nodes(struct state *st, npath_node_t *npath_node, int (*cb)(struct state *st, npath_node_t *npath_node))
{
    if (npath_node->seqn) /* node already output */
        return;

    if (npath_node->prev) {
        walk_new_nodes(st, npath_node->prev, cb); /* recurse */
        npath_node->depth = npath_node->prev->depth + 1;
    }
    else npath_node->depth = 0;
    npath_node->seqn = ++st->seqn;

    if (cb)
        cb(st, npath_node);

    return;
}

int
dump_path(struct state *st, npath_node_t *npath_node, UV attr_type, const char *attr_name, UV attr_value)
{
    if (!attr_type && !attr_value)
        return 0;
    walk_new_nodes(st, npath_node, print_formatted_node);
    print_indent(npath_node->depth+1);
    if (attr_type) {
        fprintf(stderr, "~NAMED('%s') %lu", attr_name, attr_value);
    }
    else {
        fprintf(stderr, "+%ld ", attr_value);
        fprintf(stderr, "%s ", attr_name);
        fprintf(stderr, "=%ld ", attr_value+st->total_size);
    }
    fprintf(stderr, "\n");
    return 0;
}

#endif /* PATH_TRACKING */


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
	= (raw_p >> ALIGN_BITS) | (raw_p << (bits - ALIGN_BITS));
    const U8 this_bit = 1 << (cooked_p & 0x7);
    U8 **leaf_p;
    U8 *leaf;
    unsigned int i;
    void **tv_p = (void **) (st->tracking);

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
#if !defined(MULTIPLICITY) || PERL_VERSION > 8 || (PERL_VERSION == 8 && PERL_SUBVERSION > 8)
    /* 5.8.8 and early have an assert() macro that uses Perl_croak, hence needs
       a my_perl under multiplicity  */
    assert(bits == 16);
#endif
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
		free_tracking_at((void **) tv[i], level);
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
    if (st->free_state_cb)
        st->free_state_cb(st);
    if (st->state_cb_data)
        Safefree(st->state_cb_data);
    free_tracking_at((void **)st->tracking, top_level);
    Safefree(st);
}

/* For now, this is somewhat a compatibility bodge until the plan comes
   together for fine grained recursion control. total_size() would recurse into
   hash and array members, whereas sv_size() would not. However, sv_size() is
   called with CvSTASH() of a CV, which means that if it (also) starts to
   recurse fully, then the size of any CV now becomes the size of the entire
   symbol table reachable from it, and potentially the entire symbol table, if
   any subroutine makes a reference to a global (such as %SIG). The historical
   implementation of total_size() didn't report "everything", and changing the
   only available size to "everything" doesn't feel at all useful.  */

#define NO_RECURSION 0
#define SOME_RECURSION 1
#define TOTAL_SIZE_RECURSION 2

static void sv_size(pTHX_ struct state *, pPATH, const SV *const, const int recurse);

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
#ifdef OA_CONDOP
    , OPc_CONDOP /* 12 */
#endif
#ifdef OA_GVOP
    , OPc_GVOP /* 13 */
#endif

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

#ifdef OA_PADOP
        case OA_PADOP: TAG;
        return OPc_PADOP;
#endif

#ifdef OA_GVOP
        case OA_GVOP: TAG;
        return OPc_GVOP;
#endif

#ifdef OA_PVOP_OR_SVOP
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
#endif

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

#ifdef OA_CONDOP
        case OA_CONDOP: TAG;
	    return OPc_CONDOP;
#endif
        }
        warn("Devel::Size: Can't determine class of operator %s, assuming BASEOP\n",
         PL_op_name[o->op_type]);
    }
    CAUGHT_EXCEPTION { }
    return OPc_BASEOP;
}

/* Figure out how much magic is attached to the SV and return the
   size */
static void
magic_size(pTHX_ const SV * const thing, struct state *st, pPATH) {
  dNPathNodes(1, NPathArg);
  MAGIC *magic_pointer = SvMAGIC(thing);

  /* Have we seen the magic pointer?  (NULL has always been seen before)  */
  while (check_new(st, magic_pointer)) {

    dNPathSetNode(magic_pointer, NPtype_MAGIC);

    ADD_SIZE(st, "mg", sizeof(MAGIC));
    /* magic vtables aren't freed when magic is freed, so don't count them.
       (They are static structures. Anything that assumes otherwise is buggy.)
    */


    TRY_TO_CATCH_SEGV {
	sv_size(aTHX_ st, NPathLink("mg_obj", NPtype_LINK), magic_pointer->mg_obj, TOTAL_SIZE_RECURSION);
	if (magic_pointer->mg_len == HEf_SVKEY) {
	    sv_size(aTHX_ st, NPathLink("mg_ptr", NPtype_LINK), (SV *)magic_pointer->mg_ptr, TOTAL_SIZE_RECURSION);
	}
#if defined(PERL_MAGIC_utf8) && defined (PERL_MAGIC_UTF8_CACHESIZE)
	else if (magic_pointer->mg_type == PERL_MAGIC_utf8) {
	    if (check_new(st, magic_pointer->mg_ptr)) {
		ADD_SIZE(st, "PERL_MAGIC_utf8", PERL_MAGIC_UTF8_CACHESIZE * 2 * sizeof(STRLEN));
	    }
	}
#endif
	else if (magic_pointer->mg_len > 0) {
	    if (check_new(st, magic_pointer->mg_ptr)) {
		ADD_SIZE(st, "mg_len", magic_pointer->mg_len);
	    }
	}

        /* Get the next in the chain */
        magic_pointer = magic_pointer->mg_moremagic;
    }
    CAUGHT_EXCEPTION { 
        if (st->dangle_whine) 
            warn( "Devel::Size: Encountered bad magic at: %p\n", magic_pointer );
    }
  }
}

static void
check_new_and_strlen(struct state *st, const char *const p, pPATH) {
    dNPathNodes(1, NPathArg->prev);
    if(check_new(st, p)) {
        dNPathSetNode(NPathArg->id, NPtype_NAME);
	ADD_SIZE(st, NPathArg->id, 1 + strlen(p));
    }
}

static void
regex_size(const REGEXP * const baseregex, struct state *st, pPATH) {
    dNPathNodes(1, NPathArg);
    if(!check_new(st, baseregex))
	return;
  dNPathSetNode("regex_size", NPtype_NAME);
  ADD_SIZE(st, "REGEXP", sizeof(REGEXP));
#if (PERL_VERSION < 11)     
  /* Note the size of the paren offset thing */
  ADD_SIZE(st, "nparens", sizeof(I32) * baseregex->nparens * 2);
  ADD_SIZE(st, "precomp", strlen(baseregex->precomp));
#else
  ADD_SIZE(st, "regexp", sizeof(struct regexp));
  ADD_SIZE(st, "nparens", sizeof(I32) * SvANY(baseregex)->nparens * 2);
  /*ADD_SIZE(st, strlen(SvANY(baseregex)->subbeg));*/
#endif
  if (st->go_yell && !st->regex_whine) {
    carp("Devel::Size: Calculated sizes for compiled regexes are incompatible, and probably always will be");
    st->regex_whine = 1;
  }
}

static void
op_size(pTHX_ const OP * const baseop, struct state *st, pPATH)
{
    /* op_size recurses to follow the chain of opcodes.
     * For the 'path' we don't want the chain to be 'nested' in the path so we
     * use ->prev in dNPathNodes.
     */
    dNPathUseParent(NPathArg);

    TRY_TO_CATCH_SEGV {
	TAG;
	if(!check_new(st, baseop))
	    return;
	TAG;
	op_size(aTHX_ baseop->op_next, st, NPathOpLink);
	TAG;
	switch (cc_opclass(baseop)) {
	case OPc_BASEOP: TAG;
	    ADD_SIZE(st, "op", sizeof(struct op));
	    TAG;break;
	case OPc_UNOP: TAG;
	    ADD_SIZE(st, "unop", sizeof(struct unop));
	    op_size(aTHX_ ((UNOP *)baseop)->op_first, st, NPathOpLink);
	    TAG;break;
	case OPc_BINOP: TAG;
	    ADD_SIZE(st, "binop", sizeof(struct binop));
	    op_size(aTHX_ ((BINOP *)baseop)->op_first, st, NPathOpLink);
	    op_size(aTHX_ ((BINOP *)baseop)->op_last, st, NPathOpLink);
	    TAG;break;
	case OPc_LOGOP: TAG;
	    ADD_SIZE(st, "logop", sizeof(struct logop));
	    op_size(aTHX_ ((BINOP *)baseop)->op_first, st, NPathOpLink);
	    op_size(aTHX_ ((LOGOP *)baseop)->op_other, st, NPathOpLink);
	    TAG;break;
#ifdef OA_CONDOP
	case OPc_CONDOP: TAG;
	    ADD_SIZE(st, "condop", sizeof(struct condop));
	    op_size(aTHX_ ((BINOP *)baseop)->op_first, st, NPathOpLink);
	    op_size(aTHX_ ((CONDOP *)baseop)->op_true, st, NPathOpLink);
	    op_size(aTHX_ ((CONDOP *)baseop)->op_false, st, NPathOpLink);
	    TAG;break;
#endif
	case OPc_LISTOP: TAG;
	    ADD_SIZE(st, "listop", sizeof(struct listop));
	    op_size(aTHX_ ((LISTOP *)baseop)->op_first, st, NPathOpLink);
	    op_size(aTHX_ ((LISTOP *)baseop)->op_last, st, NPathOpLink);
	    TAG;break;
	case OPc_PMOP: TAG;
	    ADD_SIZE(st, "pmop", sizeof(struct pmop));
	    op_size(aTHX_ ((PMOP *)baseop)->op_first, st, NPathOpLink);
	    op_size(aTHX_ ((PMOP *)baseop)->op_last, st, NPathOpLink);
#if PERL_VERSION < 9 || (PERL_VERSION == 9 && PERL_SUBVERSION < 5)
	    op_size(aTHX_ ((PMOP *)baseop)->op_pmreplroot, st, NPathOpLink);
	    op_size(aTHX_ ((PMOP *)baseop)->op_pmreplstart, st, NPathOpLink);
#endif
	    /* This is defined away in perl 5.8.x, but it is in there for
	       5.6.x */
#ifdef PM_GETRE
	    regex_size(PM_GETRE((PMOP *)baseop), st, NPathLink("PM_GETRE", NPtype_LINK));
#else
	    regex_size(((PMOP *)baseop)->op_pmregexp, st, NPathLink("op_pmregexp", NPtype_LINK));
#endif
	    TAG;break;
	case OPc_SVOP: TAG;
	    ADD_SIZE(st, "svop", sizeof(struct svop));
	    if (!(baseop->op_type == OP_AELEMFAST
		  && baseop->op_flags & OPf_SPECIAL)) {
		/* not an OP_PADAV replacement */
		sv_size(aTHX_ st, NPathLink("SVOP", NPtype_LINK), ((SVOP *)baseop)->op_sv, SOME_RECURSION);
	    }
	    TAG;break;
#ifdef OA_PADOP
      case OPc_PADOP: TAG;
	  ADD_SIZE(st, "padop", sizeof(struct padop));
	  TAG;break;
#endif
#ifdef OA_GVOP
      case OPc_GVOP: TAG;
	  ADD_SIZE(st, "gvop", sizeof(struct gvop));
	  sv_size(aTHX_ st, NPathLink("GVOP", NPtype_LINK), ((GVOP *)baseop)->op_gv, SOME_RECURSION);
	  TAG;break;
#endif
	case OPc_PVOP: TAG;
	    check_new_and_strlen(st, ((PVOP *)baseop)->op_pv, NPathLink("op_pv", NPtype_LINK));
	    TAG;break;
	case OPc_LOOP: TAG;
	    ADD_SIZE(st, "loop", sizeof(struct loop));
	    op_size(aTHX_ ((LOOP *)baseop)->op_first, st, NPathOpLink);
	    op_size(aTHX_ ((LOOP *)baseop)->op_last, st, NPathOpLink);
	    op_size(aTHX_ ((LOOP *)baseop)->op_redoop, st, NPathOpLink);
	    op_size(aTHX_ ((LOOP *)baseop)->op_nextop, st, NPathOpLink);
	    op_size(aTHX_ ((LOOP *)baseop)->op_lastop, st, NPathOpLink);
	    TAG;break;
	case OPc_COP: TAG;
        {
          COP *basecop;
          basecop = (COP *)baseop;
          ADD_SIZE(st, "cop", sizeof(struct cop));

          /* Change 33656 by nicholas@mouse-mill on 2008/04/07 11:29:51
          Eliminate cop_label from struct cop by storing a label as the first
          entry in the hints hash. Most statements don't have labels, so this
          will save memory. Not sure how much. 
          The check below will be incorrect fail on bleadperls
          before 5.11 @33656, but later than 5.10, producing slightly too
          small memory sizes on these Perls. */
#if (PERL_VERSION < 11)
          check_new_and_strlen(st, basecop->cop_label, NPathLink("cop_label", NPtype_LINK));
#endif
#ifdef USE_ITHREADS
          check_new_and_strlen(st, basecop->cop_file, NPathLink("cop_file", NPtype_LINK));
          check_new_and_strlen(st, basecop->cop_stashpv, NPathLink("cop_stashpv", NPtype_LINK));
#else
	  sv_size(aTHX_ st, NPathLink("cop_stash", NPtype_LINK), (SV *)basecop->cop_stash, SOME_RECURSION);
	  sv_size(aTHX_ st, NPathLink("cop_filegv", NPtype_LINK), (SV *)basecop->cop_filegv, SOME_RECURSION);
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
}

static void
hek_size(pTHX_ struct state *st, HEK *hek, U32 shared, pPATH)
{
    dNPathUseParent(NPathArg);
    /* Hash keys can be shared. Have we seen this before? */
    if (!check_new(st, hek))
	return;
    ADD_SIZE(st, "hek_len", HEK_BASESIZE + hek->hek_len
#if PERL_VERSION < 8
	+ 1 /* No hash key flags prior to 5.8.0  */
#else
	+ 2
#endif
	);
    if (shared) {
#if PERL_VERSION < 10
	ADD_SIZE(st, "he", sizeof(struct he));
#else
	ADD_SIZE(st, "shared_he", STRUCT_OFFSET(struct shared_he, shared_he_hek));
#endif
    }
}


#if PERL_VERSION < 8 || PERL_SUBVERSION < 9
#  define SVt_LAST 16
#endif

#ifdef PURIFY
#  define MAYBE_PURIFY(normal, pure) (pure)
#  define MAYBE_OFFSET(struct_name, member) 0
#else
#  define MAYBE_PURIFY(normal, pure) (normal)
#  define MAYBE_OFFSET(struct_name, member) STRUCT_OFFSET(struct_name, member)
#endif

const U8 body_sizes[SVt_LAST] = {
#if PERL_VERSION < 9
     0,                                                       /* SVt_NULL */
     MAYBE_PURIFY(sizeof(IV), sizeof(XPVIV)),                 /* SVt_IV */
     MAYBE_PURIFY(sizeof(NV), sizeof(XPVNV)),                 /* SVt_NV */
     sizeof(XRV),                                             /* SVt_RV */
     sizeof(XPV),                                             /* SVt_PV */
     sizeof(XPVIV),                                           /* SVt_PVIV */
     sizeof(XPVNV),                                           /* SVt_PVNV */
     sizeof(XPVMG),                                           /* SVt_PVMG */
     sizeof(XPVBM),                                           /* SVt_PVBM */
     sizeof(XPVLV),                                           /* SVt_PVLV */
     sizeof(XPVAV),                                           /* SVt_PVAV */
     sizeof(XPVHV),                                           /* SVt_PVHV */
     sizeof(XPVCV),                                           /* SVt_PVCV */
     sizeof(XPVGV),                                           /* SVt_PVGV */
     sizeof(XPVFM),                                           /* SVt_PVFM */
     sizeof(XPVIO)                                            /* SVt_PVIO */
#elif PERL_VERSION == 10 && PERL_SUBVERSION == 0
     0,                                                       /* SVt_NULL */
     0,                                                       /* SVt_BIND */
     0,                                                       /* SVt_IV */
     MAYBE_PURIFY(sizeof(NV), sizeof(XPVNV)),                 /* SVt_NV */
     0,                                                       /* SVt_RV */
     MAYBE_PURIFY(sizeof(xpv_allocated), sizeof(XPV)),        /* SVt_PV */
     MAYBE_PURIFY(sizeof(xpviv_allocated), sizeof(XPVIV)),/* SVt_PVIV */
     sizeof(XPVNV),                                           /* SVt_PVNV */
     sizeof(XPVMG),                                           /* SVt_PVMG */
     sizeof(XPVGV),                                           /* SVt_PVGV */
     sizeof(XPVLV),                                           /* SVt_PVLV */
     MAYBE_PURIFY(sizeof(xpvav_allocated), sizeof(XPVAV)),/* SVt_PVAV */
     MAYBE_PURIFY(sizeof(xpvhv_allocated), sizeof(XPVHV)),/* SVt_PVHV */
     MAYBE_PURIFY(sizeof(xpvcv_allocated), sizeof(XPVCV)),/* SVt_PVCV */
     MAYBE_PURIFY(sizeof(xpvfm_allocated), sizeof(XPVFM)),/* SVt_PVFM */
     sizeof(XPVIO),                                           /* SVt_PVIO */
#elif PERL_VERSION == 10 && PERL_SUBVERSION == 1
     0,                                                       /* SVt_NULL */
     0,                                                       /* SVt_BIND */
     0,                                                       /* SVt_IV */
     MAYBE_PURIFY(sizeof(NV), sizeof(XPVNV)),                 /* SVt_NV */
     0,                                                       /* SVt_RV */
     sizeof(XPV) - MAYBE_OFFSET(XPV, xpv_cur),                /* SVt_PV */
     sizeof(XPVIV) - MAYBE_OFFSET(XPV, xpv_cur),              /* SVt_PVIV */
     sizeof(XPVNV),                                           /* SVt_PVNV */
     sizeof(XPVMG),                                           /* SVt_PVMG */
     sizeof(XPVGV),                                           /* SVt_PVGV */
     sizeof(XPVLV),                                           /* SVt_PVLV */
     sizeof(XPVAV) - MAYBE_OFFSET(XPVAV, xav_fill),           /* SVt_PVAV */
     sizeof(XPVHV) - MAYBE_OFFSET(XPVHV, xhv_fill),           /* SVt_PVHV */
     sizeof(XPVCV) - MAYBE_OFFSET(XPVCV, xpv_cur),            /* SVt_PVCV */
     sizeof(XPVFM) - MAYBE_OFFSET(XPVFM, xpv_cur),            /* SVt_PVFM */
     sizeof(XPVIO)                                            /* SVt_PVIO */
#elif PERL_VERSION < 13
     0,                                                       /* SVt_NULL */
     0,                                                       /* SVt_BIND */
     0,                                                       /* SVt_IV */
     MAYBE_PURIFY(sizeof(NV), sizeof(XPVNV)),                 /* SVt_NV */
     sizeof(XPV) - MAYBE_OFFSET(XPV, xpv_cur),                /* SVt_PV */
     sizeof(XPVIV) - MAYBE_OFFSET(XPV, xpv_cur),              /* SVt_PVIV */
     sizeof(XPVNV),                                           /* SVt_PVNV */
     sizeof(XPVMG),                                           /* SVt_PVMG */
     sizeof(regexp) - MAYBE_OFFSET(regexp, xpv_cur),          /* SVt_REGEXP */
     sizeof(XPVGV),                                           /* SVt_PVGV */
     sizeof(XPVLV),                                           /* SVt_PVLV */
     sizeof(XPVAV) - MAYBE_OFFSET(XPVAV, xav_fill),           /* SVt_PVAV */
     sizeof(XPVHV) - MAYBE_OFFSET(XPVHV, xhv_fill),           /* SVt_PVHV */
     sizeof(XPVCV) - MAYBE_OFFSET(XPVCV, xpv_cur),            /* SVt_PVCV */
     sizeof(XPVFM) - MAYBE_OFFSET(XPVFM, xpv_cur),            /* SVt_PVFM */
     sizeof(XPVIO)                                            /* SVt_PVIO */
#else
     0,                                                       /* SVt_NULL */
     0,                                                       /* SVt_BIND */
     0,                                                       /* SVt_IV */
     MAYBE_PURIFY(sizeof(NV), sizeof(XPVNV)),                 /* SVt_NV */
     sizeof(XPV) - MAYBE_OFFSET(XPV, xpv_cur),                /* SVt_PV */
     sizeof(XPVIV) - MAYBE_OFFSET(XPV, xpv_cur),              /* SVt_PVIV */
     sizeof(XPVNV) - MAYBE_OFFSET(XPV, xpv_cur),              /* SVt_PVNV */
     sizeof(XPVMG),                                           /* SVt_PVMG */
     sizeof(regexp),                                          /* SVt_REGEXP */
     sizeof(XPVGV),                                           /* SVt_PVGV */
     sizeof(XPVLV),                                           /* SVt_PVLV */
     sizeof(XPVAV),                                           /* SVt_PVAV */
     sizeof(XPVHV),                                           /* SVt_PVHV */
     sizeof(XPVCV),                                           /* SVt_PVCV */
     sizeof(XPVFM),                                           /* SVt_PVFM */
     sizeof(XPVIO)                                            /* SVt_PVIO */
#endif
};


static void
padlist_size(pTHX_ struct state *const st, pPATH, PADLIST *padlist,
	const int recurse)
{
    dNPathUseParent(NPathArg);
    /* based on Perl_do_dump_pad() */
    const AV *pad_name;
    SV **pname;
    I32 ix;              

    if (!padlist) {
        return;
    }
    pad_name = MUTABLE_AV(*av_fetch(MUTABLE_AV(padlist), 0, FALSE));
    pname = AvARRAY(pad_name);

    for (ix = 1; ix <= AvFILLp(pad_name); ix++) {
        const SV *namesv = pname[ix];
        if (namesv && namesv == &PL_sv_undef) {
            namesv = NULL;
        }
        if (namesv) {
            if (SvFAKE(namesv))
                ADD_ATTR(st, 1, SvPVX_const(namesv), ix);
            else
                ADD_ATTR(st, 1, SvPVX_const(namesv), ix);
        }
        else {
            ADD_ATTR(st, 1, "SVs_PADTMP", ix);
        }

    }
    sv_size(aTHX_ st, NPathArg, (SV*)padlist, recurse);
}


static void
sv_size(pTHX_ struct state *const st, pPATH, const SV * const orig_thing,
	const int recurse) {
  const SV *thing = orig_thing;
  dNPathNodes(3, NPathArg);
  U32 type;

  if(!check_new(st, orig_thing))
      return;

  type = SvTYPE(thing);
  if (type > SVt_LAST) {
      warn("Devel::Size: Unknown variable type: %d encountered\n", type);
      return;
  }
  dNPathSetNode(thing, NPtype_SV);
  ADD_SIZE(st, "sv", sizeof(SV) + body_sizes[type]);

  if (type >= SVt_PVMG) {
      magic_size(aTHX_ thing, st, NPathLink(NULL, 0));
  }

  switch (type) {
#if (PERL_VERSION < 11)
    /* Is it a reference? */
  case SVt_RV: TAG;
#else
  case SVt_IV: TAG;
#endif
    if(recurse && SvROK(thing))
	sv_size(aTHX_ st, NPathLink("RV", NPtype_LINK), SvRV_const(thing), recurse);
    TAG;break;

  case SVt_PVAV: TAG;
    /* Is there anything in the array? */
    if (AvMAX(thing) != -1) {
      /* an array with 10 slots has AvMax() set to 9 - te 2007-04-22 */
      ADD_SIZE(st, "av_max", sizeof(SV *) * (AvMAX(thing) + 1));
      dbg_printf(("total_size: %li AvMAX: %li av_len: $i\n", st->total_size, AvMAX(thing), av_len((AV*)thing)));

      if (recurse >= TOTAL_SIZE_RECURSION) {
	  SSize_t i = AvFILLp(thing) + 1;

	  while (i--)
	      sv_size(aTHX_ st, NPathLink("AVelem", NPtype_LINK), AvARRAY(thing)[i], recurse);
      }
    }
    /* Add in the bits on the other side of the beginning */

    dbg_printf(("total_size %li, sizeof(SV *) %li, AvARRAY(thing) %li, AvALLOC(thing)%li , sizeof(ptr) %li \n", 
        st->total_size, sizeof(SV*), AvARRAY(thing), AvALLOC(thing), sizeof( thing )));

    /* under Perl 5.8.8 64bit threading, AvARRAY(thing) was a pointer while AvALLOC was 0,
       resulting in grossly overstated sized for arrays. Technically, this shouldn't happen... */
    if (AvALLOC(thing) != 0) {
      ADD_SIZE(st, "AvALLOC", (sizeof(SV *) * (AvARRAY(thing) - AvALLOC(thing))));
      }
#if (PERL_VERSION < 9)
    /* Is there something hanging off the arylen element?
       Post 5.9.something this is stored in magic, so will be found there,
       and Perl_av_arylen_p() takes a non-const AV*, hence compilers rightly
       complain about AvARYLEN() passing thing to it.  */
    sv_size(aTHX_ st, NPathLink("ARYLEN", NPtype_LINK), AvARYLEN(thing), recurse);
#endif
    TAG;break;
  case SVt_PVHV: TAG;
    /* Now the array of buckets */
    ADD_SIZE(st, "hv_max", (sizeof(HE *) * (HvMAX(thing) + 1)));
    if (HvENAME(thing)) {
        ADD_ATTR(st, 1, HvENAME(thing), 0);
    }
    /* Now walk the bucket chain */
    if (HvARRAY(thing)) {
      HE *cur_entry;
      UV cur_bucket = 0;
      dNPathSetNode("HvARRAY", NPtype_LINK);
      for (cur_bucket = 0; cur_bucket <= HvMAX(thing); cur_bucket++) {
        cur_entry = *(HvARRAY(thing) + cur_bucket);
        while (cur_entry) {
          ADD_SIZE(st, "he", sizeof(HE));
	  hek_size(aTHX_ st, cur_entry->hent_hek, HvSHAREKEYS(thing), NPathLink("hent_hek", NPtype_LINK));
	  if (recurse >= TOTAL_SIZE_RECURSION)
	      sv_size(aTHX_ st, NPathLink("HeVAL", NPtype_LINK), HeVAL(cur_entry), recurse);
          cur_entry = cur_entry->hent_next;
        }
      }
    }
#ifdef HvAUX
    if (SvOOK(thing)) {
	/* This direct access is arguably "naughty": */
	struct mro_meta *meta = HvAUX(thing)->xhv_mro_meta;
#if PERL_VERSION > 13 || PERL_SUBVERSION > 8
	/* As is this: */
	I32 count = HvAUX(thing)->xhv_name_count;

	if (count) {
	    HEK **names = HvAUX(thing)->xhv_name_u.xhvnameu_names;
	    if (count < 0)
		count = -count;
	    while (--count)
		hek_size(aTHX_ st, names[count], 1, NPathLink("HvAUXelem", NPtype_LINK));
	}
	else
#endif
	{
	    hek_size(aTHX_ st, HvNAME_HEK(thing), 1, NPathLink("HvNAME_HEK", NPtype_LINK));
	}

	ADD_SIZE(st, "xpvhv_aux", sizeof(struct xpvhv_aux));
	if (meta) {
	    ADD_SIZE(st, "mro_meta", sizeof(struct mro_meta));
	    sv_size(aTHX_ st, NPathLink("mro_nextmethod", NPtype_LINK), (SV *)meta->mro_nextmethod, TOTAL_SIZE_RECURSION);
#if PERL_VERSION > 10 || (PERL_VERSION == 10 && PERL_SUBVERSION > 0)
	    sv_size(aTHX_ st, NPathLink("isa", NPtype_LINK), (SV *)meta->isa, TOTAL_SIZE_RECURSION);
#endif
#if PERL_VERSION > 10
	    sv_size(aTHX_ st, NPathLink("mro_linear_all", NPtype_LINK), (SV *)meta->mro_linear_all, TOTAL_SIZE_RECURSION);
	    sv_size(aTHX_ st, NPathLink("mro_linear_current", NPtype_LINK), meta->mro_linear_current, TOTAL_SIZE_RECURSION);
#else
	    sv_size(aTHX_ st, NPathLink("mro_linear_dfs", NPtype_LINK), (SV *)meta->mro_linear_dfs, TOTAL_SIZE_RECURSION);
	    sv_size(aTHX_ st, NPathLink("mro_linear_c3", NPtype_LINK), (SV *)meta->mro_linear_c3, TOTAL_SIZE_RECURSION);
#endif
	}
    }
#else
    check_new_and_strlen(st, HvNAME_get(thing), NPathLink("HvNAME", NPtype_LINK));
#endif
    TAG;break;


  case SVt_PVFM: TAG;
    padlist_size(aTHX_ st, NPathLink("CvPADLIST", NPtype_LINK), CvPADLIST(thing), SOME_RECURSION);
    sv_size(aTHX_ st, NPathLink("CvOUTSIDE", NPtype_LINK), (SV *)CvOUTSIDE(thing), recurse);

    if (st->go_yell && !st->fm_whine) {
      carp("Devel::Size: Calculated sizes for FMs are incomplete");
      st->fm_whine = 1;
    }
    goto freescalar;

  case SVt_PVCV: TAG;
    sv_size(aTHX_ st, NPathLink("CvSTASH", NPtype_LINK), (SV *)CvSTASH(thing), SOME_RECURSION);
    sv_size(aTHX_ st, NPathLink("SvSTASH", NPtype_LINK), (SV *)SvSTASH(thing), SOME_RECURSION);
    sv_size(aTHX_ st, NPathLink("CvGV", NPtype_LINK), (SV *)CvGV(thing), SOME_RECURSION);
    padlist_size(aTHX_ st, NPathLink("CvPADLIST", NPtype_LINK), CvPADLIST(thing), SOME_RECURSION);
    sv_size(aTHX_ st, NPathLink("CvOUTSIDE", NPtype_LINK), (SV *)CvOUTSIDE(thing), recurse);
    if (CvISXSUB(thing)) {
	sv_size(aTHX_ st, NPathLink("cv_const_sv", NPtype_LINK), cv_const_sv((CV *)thing), recurse);
    } else {
	op_size(aTHX_ CvSTART(thing), st, NPathLink("CvSTART", NPtype_LINK));
	op_size(aTHX_ CvROOT(thing), st, NPathLink("CvROOT", NPtype_LINK));
    }
    goto freescalar;

  case SVt_PVIO: TAG;
    /* Some embedded char pointers */
    check_new_and_strlen(st, ((XPVIO *) SvANY(thing))->xio_top_name, NPathLink("xio_top_name", NPtype_LINK));
    check_new_and_strlen(st, ((XPVIO *) SvANY(thing))->xio_fmt_name, NPathLink("xio_fmt_name", NPtype_LINK));
    check_new_and_strlen(st, ((XPVIO *) SvANY(thing))->xio_bottom_name, NPathLink("xio_bottom_name", NPtype_LINK));
    /* Throw the GVs on the list to be walked if they're not-null */
    sv_size(aTHX_ st, NPathLink("xio_top_gv", NPtype_LINK), (SV *)((XPVIO *) SvANY(thing))->xio_top_gv, recurse);
    sv_size(aTHX_ st, NPathLink("xio_bottom_gv", NPtype_LINK), (SV *)((XPVIO *) SvANY(thing))->xio_bottom_gv, recurse);
    sv_size(aTHX_ st, NPathLink("xio_fmt_gv", NPtype_LINK), (SV *)((XPVIO *) SvANY(thing))->xio_fmt_gv, recurse);

    /* Only go trotting through the IO structures if they're really
       trottable. If USE_PERLIO is defined we can do this. If
       not... we can't, so we don't even try */
#ifdef USE_PERLIO
    /* Dig into xio_ifp and xio_ofp here */
    warn("Devel::Size: Can't size up perlio layers yet\n");
#endif
    goto freescalar;

  case SVt_PVLV: TAG;
#if (PERL_VERSION < 9)
    goto freescalar;
#endif

  case SVt_PVGV: TAG;
    if(isGV_with_GP(thing)) {
#ifdef GvNAME_HEK
	hek_size(aTHX_ st, GvNAME_HEK(thing), 1, NPathLink("GvNAME_HEK", NPtype_LINK));
#else	
	ADD_SIZE(st, "GvNAMELEN", GvNAMELEN(thing));
#endif
        ADD_ATTR(st, 1, GvNAME_get(thing), 0);
#ifdef GvFILE_HEK
	hek_size(aTHX_ st, GvFILE_HEK(thing), 1, NPathLink("GvFILE_HEK", NPtype_LINK));
#elif defined(GvFILE)
#  if !defined(USE_ITHREADS) || (PERL_VERSION > 8 || (PERL_VERSION == 8 && PERL_SUBVERSION > 8))
	/* With itreads, before 5.8.9, this can end up pointing to freed memory
	   if the GV was created in an eval, as GvFILE() points to CopFILE(),
	   and the relevant COP has been freed on scope cleanup after the eval.
	   5.8.9 adds a binary compatible fudge that catches the vast majority
	   of cases. 5.9.something added a proper fix, by converting the GP to
	   use a shared hash key (porperly reference counted), instead of a
	   char * (owned by who knows? possibly no-one now) */
	check_new_and_strlen(st, GvFILE(thing), NPathLink("GvFILE", NPtype_LINK));
#  endif
#endif
	/* Is there something hanging off the glob? */
	if (check_new(st, GvGP(thing))) {
	    ADD_SIZE(st, "GP", sizeof(GP));
	    sv_size(aTHX_ st, NPathLink("gp_sv", NPtype_LINK), (SV *)(GvGP(thing)->gp_sv), recurse);
	    sv_size(aTHX_ st, NPathLink("gp_form", NPtype_LINK), (SV *)(GvGP(thing)->gp_form), recurse);
	    sv_size(aTHX_ st, NPathLink("gp_av", NPtype_LINK), (SV *)(GvGP(thing)->gp_av), recurse);
	    sv_size(aTHX_ st, NPathLink("gp_hv", NPtype_LINK), (SV *)(GvGP(thing)->gp_hv), recurse);
	    sv_size(aTHX_ st, NPathLink("gp_egv", NPtype_LINK), (SV *)(GvGP(thing)->gp_egv), recurse);
	    sv_size(aTHX_ st, NPathLink("gp_cv", NPtype_LINK), (SV *)(GvGP(thing)->gp_cv), recurse);
	}
#if (PERL_VERSION >= 9)
	TAG; break;
#endif
    }
#if PERL_VERSION <= 8
  case SVt_PVBM: TAG;
#endif
  case SVt_PVMG: TAG;
  case SVt_PVNV: TAG;
  case SVt_PVIV: TAG;
  case SVt_PV: TAG;
  freescalar:
    if(recurse && SvROK(thing))
	sv_size(aTHX_ st, NPathLink("RV", NPtype_LINK), SvRV_const(thing), recurse);
    else if (SvIsCOW_shared_hash(thing))
	hek_size(aTHX_ st, SvSHARED_HEK_FROM_PV(SvPVX(thing)), 1, NPathLink("SvSHARED_HEK_FROM_PV", NPtype_LINK));
    else
	ADD_SIZE(st, "SvLEN", SvLEN(thing));

    if(SvOOK(thing)) {
	STRLEN len;
	SvOOK_offset(thing, len);
	ADD_SIZE(st, "SvOOK", len);
    }
    TAG;break;

  }
  return;
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
    check_new(st, &PL_sv_undef);
    check_new(st, &PL_sv_no);
    check_new(st, &PL_sv_yes);
#if PERL_VERSION > 8 || (PERL_VERSION == 8 && PERL_SUBVERSION > 0)
    check_new(st, &PL_sv_placeholder);
#endif
    return st;
}

MODULE = Devel::Size        PACKAGE = Devel::Size       

PROTOTYPES: DISABLE

UV
size(orig_thing)
     SV *orig_thing
ALIAS:
    total_size = TOTAL_SIZE_RECURSION
CODE:
{
  SV *thing = orig_thing;
  struct state *st = new_state(aTHX);
  
  /* If they passed us a reference then dereference it. This is the
     only way we can check the sizes of arrays and hashes */
  if (SvROK(thing)) {
    thing = SvRV(thing);
  }
#ifdef PATH_TRACKING
  st->add_attr_cb = dump_path;
  if (st->add_attr_cb)
    sv_dump(thing);
#endif
  sv_size(aTHX_ st, NULL, thing, ix);
  RETVAL = st->total_size;
  free_state(st);
}
OUTPUT:
  RETVAL
