(require 'ert)

(ert-deftest test-iove/expand-print-macro ()
  (should (equal (iove/expand-print-macro 3 "n x")
                 "print(f'(:num 3 :asgn (\"n\" \"{n}\" \"x\" \"{x}\"))')"))
  (should (equal (iove/expand-print-macro 3 "?(i%2) i")
                 "if (i%2): print(f'(:num 3 :asgn (\"i\" \"{i}\"))')"))
  )

(ert-deftest test-iove/expand-line ()
  (should (equal (iove/expand-line 3 "n = 3") nil))
  (should (equal (iove/expand-line 3 "n = 3 ## n") "n = 3 ; print(f'(:num 3 :asgn (\"n\" \"{n}\"))')"))
  (should (equal (iove/expand-line 3 "    x = 5 ## ") "    x = 5 ; print(f'(:num 3 :asgn (\"x\" \"{x}\"))')"))

  (should (equal (iove/expand-line 3 "edges = [(1,2)] ## > :graph") "edges = [(1,2)] ; print(f'(:num 3 :asgn (\"edges\" \"{edges}\") :action :graph)')"))
  (should (equal (iove/expand-line 3 "edges = [(1,2)] ## edges > :graph") "edges = [(1,2)] ; print(f'(:num 3 :asgn (\"edges\" \"{edges}\") :action :graph)')"))
  (should (equal (iove/expand-line 3 "## edges > :graph") "print(f'(:num 3 :asgn (\"edges\" \"{edges}\") :action :graph)')"))
  )

(ert-deftest test-iove/parse-error ()
  (let ((tb-2 "Traceback (most recent call last):
  File \"<string>\", line 8, in __PYTHON_EL_eval
  File \"/usr/lib/python3.9/ast.py\", line 50, in parse
    return compile(source, filename, mode, flags,
  File \"<string>\", line 24
    def main():
    ^
IndentationError: expected an indented block"))
    (should (equal (iove/parse-error tb-2) '(:num 24 :text "IndentationError: expected an indented block")))
  ))

(ert-deftest test-iove/extract-lvals ()
  (should (equal (iove/extract-lvals "a, b = 5, 7" "") "a b"))
  (should (equal (iove/extract-lvals "    a, b = 5, 7" "") "a b"))
  (should (equal (iove/extract-lvals "a = 'abc'" "") "a"))
  (should-error (iove/extract-lvals "a += 10" "")))

(ert-deftest test-s-split-trim ()
  (should (equal (s-split-trim "##" "abc ## def") '("abc" "def"))))
