from django.test import TestCase

# Create your tests here.
class MyTestCase(TestCase):
    def test_something(self):
        self.assertTrue(True)

    def test_something_one(self):
        self.assertFalse(False)