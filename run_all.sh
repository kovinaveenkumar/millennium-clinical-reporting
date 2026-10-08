#!/usr/bin/env bash
# Build -> rules -> validate (stops on failure) -> publish -> charts -> RCA/tuning evidence -> tests
set -euo pipefail
cd "$(dirname "$0")"
PY=${PY:-python}
$PY src/generate_data.py
$PY src/discern_rules.py
$PY src/validate.py            # exits 1 on any failed check: nothing gets published
$PY src/build_html.py "$@"
$PY src/make_charts.py
$PY src/rca.py
$PY src/tune.py
$PY -m pytest -q
