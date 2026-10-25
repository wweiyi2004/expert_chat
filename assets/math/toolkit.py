"""Trusted, bounded mathematical worker. Input is data, never Python code.

Do not replace the AST interpreter with sympify/parse_expr/eval: those accept
Python evaluation. The parent enforces a process deadline as well.
"""
import ast
import html
import json
import math
import sys

try:
    import sympy as s
except ImportError:
    print(json.dumps({'ok': False, 'code': 'dependency_missing',
                      'message': 'Install Python 3 and SymPy 1.14: python -m pip install sympy==1.14.0'}))
    sys.exit(0)

FUNCTIONS = {name: getattr(s, name) for name in
             ('sqrt', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'exp', 'log', 'Abs')}
CONSTANTS = {'pi': s.pi, 'E': s.E, 'I': s.I}


def expression(text, restrictions=None):
    if not isinstance(text, str) or not 0 < len(text) <= 2048:
        raise ValueError('expression must be 1..2048 characters')
    tree = ast.parse(text, mode='eval')
    if len(list(ast.walk(tree))) > 256:
        raise ValueError('expression is too complex')

    def visit(node, depth=0):
        if depth > 32:
            raise ValueError('expression nesting exceeds 32')
        child = lambda n: visit(n, depth + 1)
        if isinstance(node, ast.Constant) and type(node.value) in (int, float):
            raw = ast.get_source_segment(text, node)
            if len(raw) > 100 or not math.isfinite(float(node.value)):
                raise ValueError('number exceeds limit')
            return s.Rational(raw)
        if isinstance(node, ast.Name) and node.id.isascii() and node.id.isalpha() and len(node.id) <= 16:
            return CONSTANTS.get(node.id, s.Symbol(node.id))
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = child(node.operand)
            return value if isinstance(node.op, ast.UAdd) else -value
        if isinstance(node, ast.BinOp):
            left, right = child(node.left), child(node.right)
            if isinstance(node.op, ast.Add): return left + right
            if isinstance(node.op, ast.Sub): return left - right
            if isinstance(node.op, ast.Mult): return left * right
            if isinstance(node.op, ast.Div):
                if right == 0: raise ValueError('division by zero is undefined')
                if restrictions is not None and right.is_zero is not False:
                    restrictions.append((right, 'nonzero'))
                return left / right
            if isinstance(node.op, ast.Pow):
                if left == 0 and (right == 0 or right.is_negative is True):
                    raise ValueError('undefined zero power')
                if restrictions is not None and right.is_negative is True and left.is_zero is not False:
                    restrictions.append((left, 'nonzero'))
                if right.is_number and (right.is_real is not True or abs(right) > 1000):
                    raise ValueError('power exceeds limit')
                if left.is_Rational and right.is_number and right.is_real:
                    bits = max(abs(int(left.p)).bit_length(), int(left.q).bit_length())
                    if bits * max(1, float(abs(right))) > 12000:
                        raise ValueError('exact integer size exceeds limit')
                return left ** right
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in FUNCTIONS and not node.keywords and len(node.args) == 1:
            argument = child(node.args[0])
            if node.func.id == 'log' and restrictions is not None and argument.is_zero is not False:
                restrictions.append((argument, 'nonzero'))
            if node.func.id == 'tan' and restrictions is not None and s.cos(argument).is_zero is not False:
                restrictions.append((s.cos(argument), 'nonzero'))
            return FUNCTIONS[node.func.id](argument)
        raise ValueError('unsupported syntax; only arithmetic, symbols and approved single-argument functions are allowed')
    result = visit(tree.body)
    if result.has(s.zoo, s.nan, s.oo, -s.oo):
        raise ValueError('undefined or non-finite expression')
    return result


def variable(value):
    value = str(value)
    if not value.isascii() or not value.isalpha() or len(value) > 16 or value in CONSTANTS:
        raise ValueError('invalid variable')
    return s.Symbol(value)


def display(value):
    return {'exact': str(value), 'latex': s.latex(value)}


def _run(data, restrictions):
    op = data.get('operation', 'exact')
    if op == 'diagnose':
        return {'backend': 'SymPy', 'version': s.__version__, 'python': sys.version.split()[0],
                'operations': ['exact', 'simplify', 'differentiate', 'integrate', 'solve', 'numeric', 'statistics', 'plot', 'verify']}
    if op == 'statistics':
        values = data.get('values', [])
        if not isinstance(values, list) or not 1 <= len(values) <= 512:
            raise ValueError('values requires 1..512 numbers')
        values = [expression(str(value)) for value in values]
        if any(value.is_real is not True or value.is_finite is not True for value in values):
            raise ValueError('statistics requires finite real values')
        count = len(values)
        mean = sum(values) / count
        # SymPy comparisons retain exact ordering for arbitrarily close rationals.
        ordered = sorted(values)
        median = ordered[count // 2] if count % 2 else (ordered[count // 2 - 1] + ordered[count // 2]) / 2
        variance = sum((value - mean) ** 2 for value in values) / count
        return {'count': count, 'mean': display(mean), 'median': display(median),
                'population_variance': display(variance),
                'sample_variance': display(variance * count / (count - 1)) if count > 1 else None}
    value = expression(data.get('expression'), restrictions)
    x = variable(data.get('variable', 'x'))
    if op == 'exact': return display(value)
    if op == 'simplify': return display(s.simplify(value))
    if op == 'differentiate': return display(s.diff(value, x))
    if op == 'integrate':
        result = s.integrate(value, x)
        return {**display(result), 'unevaluated': result.has(s.Integral), 'constant_of_integration': 'C'}
    if op == 'solve':
        domain = s.S.Reals
        for excluded, _ in restrictions:
            if excluded.free_symbols <= {x}:
                domain = domain - s.solveset(excluded, x, domain=s.S.Reals)
        return {'solutions': display(s.solveset(value, x, domain=domain)),
                'domain': 'real', 'equation': str(value) + ' = 0'}
    if op == 'numeric':
        digits = data.get('digits', 30)
        if type(digits) is not int or not 2 <= digits <= 100:
            raise ValueError('digits must be 2..100')
        if value.free_symbols: raise ValueError('numeric result still contains variables')
        return {'numeric': str(s.N(value, digits)), 'digits': digits, **display(value)}
    if op == 'verify':
        residual = s.simplify(value - expression(data.get('rhs'), restrictions))
        # A nonzero symbolic residual alone does not prove an inequality.
        verdict = True if residual == 0 else False if residual.is_zero is False else None
        return {'equal': verdict, 'residual': display(residual),
                'conditional': bool(restrictions),
                'meaning': 'symbolic equality only where both original expressions are defined, subject to listed exclusions and complex principal-branch conventions; null means inconclusive'}
    if op == 'plot':
        if value.free_symbols - {x}: raise ValueError('plot has unbound symbols')
        lo, hi = expression(str(data.get('min', -10))), expression(str(data.get('max', 10)))
        if any(v.is_real is not True or v.is_finite is not True for v in (lo, hi)):
            raise ValueError('plot range must be finite real numbers')
        lo, hi = float(lo), float(hi)
        if not lo < hi or abs(lo) > 1e6 or abs(hi) > 1e6: raise ValueError('invalid plot range')
        points = []
        for i in range(201):
            coordinate = lo + (hi - lo) * i / 200
            if any(excluded.subs(x, s.Float(coordinate)).is_zero is True for excluded, _ in restrictions):
                points.append([coordinate, None])
                continue
            result = value.subs(x, s.Float(coordinate)).evalf(15)
            y = float(result) if result.is_real is True and result.is_finite is True else None
            points.append([coordinate, y if y is not None and abs(y) < 1e12 else None])
        ys = [p[1] for p in points if p[1] is not None]
        if not ys: raise ValueError('no finite real samples in range')
        ymin, ymax = min(ys), max(ys)
        if ymin == ymax: ymin, ymax = ymin - 1, ymax + 1
        segments, current = [], []
        for px, py in points:
            if py is None:
                if current: segments.append(current)
                current = []
            else: current.append(f'{30 + (px-lo)/(hi-lo)*580:.2f},{270-(py-ymin)/(ymax-ymin)*240:.2f}')
        if current: segments.append(current)
        paths = ''.join('<polyline fill="none" stroke="#2563eb" stroke-width="2" points="' + ' '.join(segment) + '"/>' for segment in segments)
        svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="640" height="320" viewBox="0 0 640 320"><rect width="640" height="320" fill="white"/><text x="30" y="18" font-size="13">{html.escape(str(value))}</text><path d="M30 30V270H610" fill="none" stroke="#444"/>{paths}<text x="30" y="305" font-size="12">x: {lo:g} .. {hi:g}; y: {ymin:g} .. {ymax:g}; 201 samples</text></svg>'
        return {'svg': svg, 'points': points, 'sample_count': 201,
                'warning': 'Sampled plot, not a proof of continuity or absence of poles.'}
    raise ValueError('unsupported operation')


def run(data):
    restrictions = []
    result = _run(data, restrictions)
    result['domain'] = result.get('domain', 'complex principal branches unless stated otherwise')
    result['original_domain_exclusions'] = sorted({str(value) + ' != 0' for value, _ in restrictions})
    return result


if __name__ == '__main__':
    try:
        raw = sys.stdin.read(32769)
        if len(raw) > 32768: raise ValueError('request exceeds 32 KiB')
        data = json.loads(raw)
        if not isinstance(data, dict): raise ValueError('request must be an object')
        result = {'ok': True, 'backend': 'SymPy', 'result': run(data)}
        output = json.dumps(result, ensure_ascii=True)
        if len(output) > 100000: raise ValueError('result exceeds output limit')
        print(output)
    except Exception as error:
        print(json.dumps({'ok': False, 'code': 'invalid_math_request', 'message': str(error)[:400]}))
