import hashlib, sys
d = sys.argv[1] + '/'
for tc in ('stable', 'nightly'):
    a = open(f'{d}o-{tc}-base/libm.rmeta', 'rb').read()
    b = open(f'{d}o-{tc}-trailing/libm.rmeta', 'rb').read()
    n = sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b))
    print(tc, 'sizes', len(a), len(b), 'differing bytes', n)
    for s, blob in (('base', a), ('trailing', b)):
        src = open(f'{d}src-{s}/lib.rs', 'rb').read()
        for alg in ('md5', 'sha1', 'sha256'):
            if hashlib.new(alg, src).digest() in blob:
                print(f'  {s}: {alg} of the source file is in the rmeta')
