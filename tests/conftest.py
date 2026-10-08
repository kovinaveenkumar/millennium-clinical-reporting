import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from report_runner import DB, connect  # noqa: E402


@pytest.fixture(scope="session")
def con():
    if not DB.exists():
        pytest.skip("data/millennium.db missing - run python src/generate_data.py")
    return connect()
