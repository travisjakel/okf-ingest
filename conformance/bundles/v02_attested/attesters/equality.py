"""Deterministic attester: compare the executed artifact against the bound one."""


def attest(receipt, expected_sql):
    return receipt["executed_sql"].strip() == expected_sql.strip()
