(assert (forall ((x Int))
		(exists ((y Int))
			(and (= (mod (+ x y) 10) 0)
			     (<= 0 y)
			     (< y 10)))))
