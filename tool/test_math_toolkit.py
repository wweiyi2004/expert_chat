"""Real backend checks; no provider requests or package installation."""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('math_worker', pathlib.Path(__file__).parents[1] / 'assets/math/toolkit.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class MathToolkitTest(unittest.TestCase):
    def test_exact_and_decimal(self):
        self.assertEqual(worker.run({'expression': '0.1+0.2'})['exact'], '3/10')
        self.assertEqual(worker.run({'expression': 'sqrt(8)'})['exact'], '2*sqrt(2)')

    def test_calculus_and_solution(self):
        self.assertEqual(worker.run({'operation': 'differentiate', 'expression': 'x**3'})['exact'], '3*x**2')
        self.assertEqual(worker.run({'operation': 'solve', 'expression': 'x**2-2'})['solutions']['exact'], '{-sqrt(2), sqrt(2)}')

    def test_verify_inconclusive(self):
        self.assertTrue(worker.run({'operation': 'verify', 'expression': '(x+1)**2', 'rhs': 'x**2+2*x+1'})['equal'])
        self.assertIsNone(worker.run({'operation': 'verify', 'expression': 'x', 'rhs': '0'})['equal'])

    def test_statistics_and_plot(self):
        result = worker.run({'operation': 'statistics', 'values': ['1', '2', '3']})
        self.assertEqual(result['sample_variance']['exact'], '1')
        self.assertEqual(result['population_variance']['exact'], '2/3')
        result = worker.run({'operation': 'plot', 'expression': 'x**2'})
        self.assertEqual(len(result['points']), 201)
        self.assertIn('<svg', result['svg'])

    def test_exact_statistics_order(self):
        result = worker.run({'operation': 'statistics', 'values': ['1+1/10**50', '1', '1+2/10**50']})
        self.assertEqual(result['median']['exact'], str(worker.expression('1+1/10**50')))

    def test_original_domain_is_retained(self):
        result = worker.run({'operation': 'verify', 'expression': 'x/x', 'rhs': '1'})
        self.assertTrue(result['conditional'])
        self.assertEqual(result['original_domain_exclusions'], ['x != 0'])
        tangent = worker.run({'operation': 'verify', 'expression': 'tan(x)*cos(x)', 'rhs': 'sin(x)'})
        self.assertTrue(tangent['conditional'])
        self.assertIn('cos(x) != 0', tangent['original_domain_exclusions'])
        plot = worker.run({'operation': 'plot', 'expression': 'x/x', 'min': -1, 'max': 1})
        self.assertIsNone(plot['points'][100][1])
        result = worker.run({'operation': 'verify', 'expression': 'x**-1*x', 'rhs': '1'})
        self.assertTrue(result['conditional'])
        for value in ['1/0', '0/0', 'log(0)', '0**-1', '0**0']:
            with self.subTest(value=value), self.assertRaises(ValueError): worker.expression(value)

    def test_rejects_python_and_large_powers(self):
        for expression in ['__import__("os")', 'x.__class__', '[x for x in (1,2)]', 'open("file")', 'lambda: 1', '2**1001', '(10**1000)**1000']:
            with self.subTest(expression=expression), self.assertRaises((ValueError, SyntaxError)):
                worker.expression(expression)


if __name__ == '__main__': unittest.main()
