import unittest

from scoring import aggregate, normalize, score


class ScoringTests(unittest.TestCase):
    def test_normalization_ignores_case_spacing_and_punctuation(self):
        self.assertEqual(normalize("  Hello, WORLD!  "), "hello world")
        result = score("Hello world", "hello, WORLD!")
        self.assertEqual(result["wer"], 0)
        self.assertEqual(result["cer"], 0)

    def test_word_and_character_accuracy_use_edit_distance(self):
        result = score("one two three", "one too three now")
        self.assertEqual(result["word_edits"], 2)
        self.assertAlmostEqual(result["wer"], 2 / 3)
        self.assertGreater(result["character_accuracy_percent"], result["word_accuracy_percent"])

    def test_aggregate_weights_reference_size(self):
        combined = aggregate([score("one", "wrong"), score("one two three", "one two three")])
        self.assertEqual(combined["word_edits"], 1)
        self.assertEqual(combined["reference_words"], 4)
        self.assertEqual(combined["word_accuracy_percent"], 75)


if __name__ == "__main__":
    unittest.main()
