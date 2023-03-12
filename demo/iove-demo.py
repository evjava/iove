from collections import defaultdict

def group_words(words):
    sort_word = lambda w: ''.join(sorted(w))
    res = defaultdict(list)
    for i, w in enumerate(words):
        res[sort_word(w)].append(w)
        ## ?(i % 2) w res[sort_word(w)]
    return dict(res)

x = group_words(["abc", "bca", "nut",  "tan", "ant"])
## x

edges = [(1, 2), (1, 3), (2, 3), (1, 4), (2, 5)]
## edges > :digraph


