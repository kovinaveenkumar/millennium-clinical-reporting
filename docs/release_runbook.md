# Release runbook

This is how I'd take one of these reports from a request to production in a typical Cerner build cycle.

1. **Intake.** Get the details clear before writing anything:
   - who's asking and what question the report needs to answer
   - how each number is defined, and what the target is
   - which prompts it needs, who will use it, and how often
   
   Those go into the spec ([report_specs.md](report_specs.md)).
2. **Build in DEV.** I write the logic in SQL first because it's quicker to iterate on. Then I write the CCL program with:
   - a standard header and mod log
   - prompts
   - code values looked up once at the top with `uar_get_code_by`
   - `parser()` for the optional facility filter
3. **Validate.** Run the data-quality checks and control totals ([test_plan.md](test_plan.md)). Recalculate the numbers a second, independent way. Spot-check five rows by FIN, and reconcile the totals with the source system.
4. **Test in CERT.** Compile and run on a short date range, then the full one. Check the explain plan and the run time. Confirm only the right positions can see the report in Explorer Menu.
5. **User acceptance.** The requester reviews the report on a real week of data and signs off.
6. **Change control.** Open a ticket listing the programs being moved, the test evidence, and a back-out plan (the previous version of each program). Move to production in the approved window.
7. **Deploy.** Add the report to Explorer Menu or the MPage, or schedule it as an ops job. The open-orders worklist, for example, runs daily at 06:00. New rules go into production in silent mode first; I review EKS_MODULE_AUDIT, then switch them on.
8. **After go-live.** Check the first few runs against the UAT numbers. Any defect gets a root-cause write-up ([rca.md](rca.md)) and a regression test so it can't come back.
