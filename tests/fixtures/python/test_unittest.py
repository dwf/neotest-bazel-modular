"""unittest.TestCase subclasses — the tricky case."""
import unittest


class TestWithBareBase(TestCase):
    """Inherits from bare 'TestCase' (imported directly)."""

    def test_method_a(self):
        pass

    def test_method_b(self):
        pass

    def setUp(self):
        # not a test — no test_ prefix
        pass


class TestWithQualifiedBase(unittest.TestCase):
    """Inherits from 'unittest.TestCase'."""

    def test_qualified(self):
        pass


class PlainClass:
    """Plain class — pytest discovers test_ methods here too."""

    def test_ignored(self):
        pass

    def test_also_ignored(self):
        pass
