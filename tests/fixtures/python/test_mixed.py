"""Mix of top-level functions and TestCase methods."""
import unittest


class MyTests(unittest.TestCase):
    def test_in_class(self):
        pass

    def setUp(self):
        pass


class Utility:
    """Plain class — pytest discovers test_ methods here too."""

    def test_not_included(self):
        pass


def test_top_level():
    pass


def not_a_test():
    pass
