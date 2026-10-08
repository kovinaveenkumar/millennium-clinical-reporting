# Release runbook: from request to production

How a report in this project would move through a typical Cerner build cycle.

1. **Intake.** Requester, business question, KPI definition, target, prompts, audience, and how often it runs. Written up in [report_specs.md](report_specs.md) before any code.
2. **Build in DEV.** Write the SQL logic first (fast to iterate), then the CCL program (`ccl/`). Standard header with a mod log, prompts, `uar_get_code_by` declares, and `parser()` for optional prompt filters.
3. **Validate.** DQ checks + control totals ([test_plan.md](test_plan.md)), an independent re-computation, a 5-row spot check by FIN, and a reconciliation to the source system.
4. **Test in CERT.** Compile, run with small and full date ranges, check the explain plan and runtime, and confirm security (only the intended positions can see the report in Explorer Menu).
5. **User acceptance.** The requester signs off on a real week of data.
6. **Change control.** Ticket with the program list, test evidence, and back-out plan (the previous object version). Move objects to PROD in the approved window.
7. **Deploy.** Add to Explorer Menu / the MPage, or schedule as an Operations job (e.g. the open-orders worklist daily at 06:00). For rules: production in **silent mode** first, review `EKS_MODULE_AUDIT`, then switch to production.
8. **Post-go-live.** Check the first runs, compare to UAT numbers, and add the report to the monitoring list. Defects go through RCA ([rca.md](rca.md)) and get a regression test.
