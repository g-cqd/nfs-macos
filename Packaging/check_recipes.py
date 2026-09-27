"""Recipes reject unsafe paths, duplicate destinations and ambiguous payloads."""
from copy import deepcopy
from recipes import load_recipe, validate_recipe


for name in ['nfsmw', 'cod4']:
    recipe = load_recipe(name)
    assert recipe['gameID'] == name
    validate_recipe(recipe)
    for change in [lambda r: r['compatibility'].append(dict(r['compatibility'][0])),
                   lambda r: r['compatibility'][0].update(path='../outside'),
                   lambda r: r['compatibility'][0].update(path='/absolute'),
                   lambda r: r.update(launcher='../escape'),
                   lambda r: r.update(gameID='bad/name'),
                   lambda r: r.update(displayName='../outside'),
                   lambda r: r.update(supportsMP='false'),
                   lambda r: r['originalFiles'].append(r['originalFiles'][0]),
                   lambda r: r['originalDirectories'].update({'main': [], 'main/child': []})]:
        altered = deepcopy(recipe)
        change(altered)
        try: validate_recipe(altered)
        except ValueError: pass
        else: raise AssertionError('Invalid recipe was accepted')
print('Recipe validation regressions passed')
