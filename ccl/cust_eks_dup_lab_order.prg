/*****************************************************************************
  Program : cust_eks_dup_lab_order
  Purpose : Logic for Discern Expert rule CUST_LAB_DUP_ORDER, called from the rule's
            LOGIC section through the EKS_EXEC_CCL_L template on order sign.
            TRUE (retval = 100) when the same orderable was ordered on the same
            encounter within the window and that order is not cancelled.
  Rule    : rules/discern_rules.json  -  analysis: docs/discern_rules.md
  Inputs  : link_encntrid, link_orderid (set by the evoking template),
            window passed as the template's OPT_PARAM (e.g. "60")
  Outputs : retval (0 = false, 100 = true), log_message, log_misc1 (prior order id,
            used by the ACTION alert text "ordered @MISC:1 ...")
------------------------------------------------------------------------------
  Mod  Date        Engineer           Description
  000  2026-10-08  Naveen Kumar Kovi  Initial release (silent mode)
*****************************************************************************/
drop program cust_eks_dup_lab_order go
create program cust_eks_dup_lab_order

declare canceled_cd = f8 with protect, constant(uar_get_code_by("MEANING", 6004, "CANCELED"))
declare window_min  = i4 with protect, noconstant(60)
if (size(trim(opt_param)) > 0) set window_min = cnvtint(opt_param) endif

set retval = 0
set log_message = "No duplicate found"

select into "nl:"
from orders new_o
   , orders prior
plan new_o
  where new_o.order_id = link_orderid
join prior
  where prior.encntr_id = link_encntrid
    and prior.catalog_cd = new_o.catalog_cd
    and prior.order_id != new_o.order_id
    and prior.order_status_cd != canceled_cd
    and prior.orig_order_dt_tm between cnvtlookbehind(build(window_min, ",MIN"), new_o.orig_order_dt_tm)
                                   and new_o.orig_order_dt_tm
order by prior.orig_order_dt_tm desc
head report
  retval = 100
  log_misc1 = cnvtstring(prior.order_id)
  log_message = build2(uar_get_code_display(new_o.catalog_cd), " ordered ",
                       trim(cnvtstring(datetimediff(new_o.orig_order_dt_tm, prior.orig_order_dt_tm, 4))),
                       " min after order ", trim(cnvtstring(prior.order_id)))
with nocounter, maxqual(prior, 1)

end
go
