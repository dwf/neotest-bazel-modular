"""Top-level test functions only — no classes."""


def test_passes():
    pass


def test_another():
    assert 1 + 1 == 2


def not_a_test():
    pass


def helper_test():
    # does NOT start with test_ so should be excluded
    pass
