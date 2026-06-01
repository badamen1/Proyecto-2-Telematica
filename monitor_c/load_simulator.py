import math
import time


def get_load() -> float:
    t = time.time()
    s1 = math.sin(t / 300)
    s2 = math.sin(t / 600 + 1.5)
    s3 = math.sin(t / 1200 + 0.7)
    raw = (s1 + s2 + s3) / 3  # range [-1, 1]
    return round(20.0 + (raw + 1.0) * 30.0, 2)  # range [20.0, 80.0]
