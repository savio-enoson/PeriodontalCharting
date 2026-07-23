import Foundation

struct TestTranscripts {
    static let student_1_ground = """
Berikut pengisian dari periodontal chart,

dimulai dari bleeding on probbing

pada gigi 16 bukal dan mesial

gigi 15 distal dan bukal

gigi 24 mesial bukal dan distal

Gigi 25 mesial bukal dan distal

Gigi 26 mesial bukal dan distal

Gigi 27 sisi mesial

padaada gigi 36 sisi mesial

Pada gigi 35 mesial, bukal dan distal

Pada gigi 34 sisi distal

Pada gigi 45 sisi distal

Pada gigi 46 mesial dan bukal

lalu plak terdapat plak pada gigi 17 pada sisi distal misial dan bukal

dilanjutkan juga pada gigi 16 15, 14, 13 12 12, 11, 21, 22, 23, 24, 25, 26, 27, 37, 36, 35, 34, 33, 32, 31, 41, 42, 43, 44, 45, 46, 47
pada sisi mesial bukal dan distal

kemudian dilanjutkan gingival margin

kita mulai dari 

gigi 17 sisi distal bukal, dan juga mesial 0, 0, minus 1

Pada gigi 1, 6, minus 1, minus 1, minus 1

Pada gigi 1, 5, minus 1, 0, 0

Pada gigi 1, 4, 13, 12, 21, 22, 23, 24, 25, 26, 27 0

Gigi 37, 36, 35, 34, 33, 32, 31, 0

41, 42, 43, 44, 0

Gigi 45, minus 1, minus 1, 0

Gigi 46, minus 2, minus 4, minus 2

Gigi 47, 0, 0, minus 1

Lalu lanjut pada probing depth

Dari sisi distal, bukal, dan juga mesial

Gigi 17 2 2 2

Gigi 16 3 4 5

Gigi 15 5 3 3

Gigi 16, 3 4 5,

gigi 15, 5 3 3,

gigi 14 2 2 2,

gigi 13 2 2 2,

gigi 12 2 2 2,

gigi 11 2 2 2,

gigi 21 2 2 2,

gigi 22 2 2 2.

Gigi 23 2 2 2

Gigi 24 3 4 5

Gigi 25, 5 5 5.

Gigi 26, 6, 6 4.

Gigi 27, 3, 2 2.

Gigi 37, 2 2 2.

Gigi 36, 4, 2 2.

Gigi 35, 4, 4, 4.

Gigi 34, 2 2 4.

Gigi 33, 4, 2, 2.

Gigi 35, 4, 4, 4.

Gigi 34, 2, 2, 4.

Gigi 33, 2, 2, 2.

Gigi 32, 2, 2, 2.

Gigi 31, 2, 2 2.

Gigi 41, 2, 2 2.

Gigi 42, 2, 2 2.

Gigi 43, 2, 2 2.

Gigi 44, 2 2 2

Gigi 45 2 2 2

Gigi 46 3 3 4

Gigi 47 2 3 3

Berikan garis warna merah berdasarkan probing depth
"""

    static let dr_lucky_ground = """
gigi 18 gak ada
2 2 2
3 4 5
5 3 3
2 2 2

resesi dari mesio bukal 17 sampai disto bukal 15 minus 1
BOP dari bukal 16 hingga bukal 15

Lanjut
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
2 2 2
3 4 5
5 5 5
6 6 4
3 2 2

BOP dari mesio bukal 24 sampai mesio bukal 27
28 gak ada

Lanjut palatal
2 2 2
2 2 4
4 4 4
4 2 2

BOP dari Mesio palatal 26 sampai Disto palatal 24.
Lanjut, 23.
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
2 2 2
2 2 2
2 2 2
4 3 3
3 3 2

15 palatal. Resesi palatal dan disto palatal 1.
16 Resesi Mesio palatal 2. palatal 4. Disto palatal 2
17 resesi mesio palatal 1
BOP dimulai dari disto lingual 15 hingga palatal 16
plaque pada semua gigi

rahang bawah
38 gak ada
2 2 2
2 2 2
2 2 2
2 2 2
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
Resesi 2 mili pada labial 31, 32, 41, 42

Lanjut 43,
2 2 2
2 2 2
2 2 2

Resesi 1 mili, distal 45
46 tidak ada

3, 2, 2

Resesi 1 mili Mesial 47

48 gak ada

Lingual
2 2 3
Resesi 1 mili Mesial
2 2 2
Resesi satu mili distal

2 2 2
2 2 2
2 2 2
2 2 2

2 2 2
2 2 2
2 2 2

Sampai 37 2
Plaque pada semua gigi

"""

    static let student_2_ground = """
Gigi 18 28 38 46 48 missing

Gigi 47
Disto bukal 2
Bukal 2
Mesio Bukal 3

Gigi 45
Disto Bukal 2
Bukal 2
Mesio Bukal 2

Gigi 44
Disto Bukal 2
Bukal 2
Mesio Bukal 2

Gigi 43
Disto Bukal 2
bukal 2
mesio bukal 2

Gigi 42
disto bukal 2
bukal 2
Mesio Bukal 2

Gigi 41
Disto Bukal 2
Bukal 2
Mesio Bukal 2

3 1
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 3 2
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 3 3
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 34
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 35
Mesio Bukal 2
Bukal 2
Disto Bukal 2


Gigi 36
Mesio Bukal 2
Bukal 2
Disto bukal 2

Gigi 37
Mesio Bukal 2
Bukal 2
disto pukal 2

---

Bagian lingual

Disto lingual 37 2
Lingual 2
Mesio lingual 2

Gigi 36
Disto lingual 2
Lingual 2
Mesio lingual 2

Gigi 3 5
disto lingual 2
mid lingual 2
misio lingual 2

Gigi 34
disto lingual 2
mid lingual 2
misio lingual 2

Gigi 33
Disto lingual 2
Lingual 2
Mesio lingual 2

Gigi 32
Disto lingual 2
Lingual 2
Mesio lingual 2

gigi 31
disto lingual 2
lingual 2
mesio lingual 2

gigi 41
disto lingual 2
lingual 2
mesial lingual 2

gigi 42
mesial lingual 2
lingual 2
distio lingual 2

Gigi 43
Mesio lingual 2
Lingual 2
Disto lingual 2

Gigi 44
Mesio lingual 2
Lingual 2
Disto lingual 2

Gigi 45
Mesio lingual 2
Lingual 2
Disto lingual 2

Gigi 47
Mesio lingual 3
Lingual 2
Disto lingual 2

resesi mesio lingual gigi 47 1
mesio bukal gigi 47 1
disto lingual gigi 45 1
disto bukal gigi 45 1 
Bukal gigi 42, 2. Bukal gigi 41, 2.
bukal gigi 31 2,
bukal gigi 32 2.

---

Lanjut ke rahang atas

{Bukal} gigi 17
Disto Bukal 17 2
Bukal 2
Mesio Bukal Pocket 2

Disto Bukal Gigi 16
probing depth 3
bukal 4
mesio bukal 5

Gigi 1 5
Disto bukal 5
Bukal 3
Mesio bukal 3

Gigi 1 4
Mesio bukal 2
Bukal 2
Mesio Bukal 2

Gigi 1, 3
Disto Bukal 2
Bukal 2
Mesio Bukal 2

Gigi 1, 2
{Mesio} Disto Bukal 2
Bukal 2
Mesio Bukal 2

Gigi 1, 1
Disto bukal 2
Bukal 2
Mesio bukal 2

Gigi 21
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 22
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 23
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 23
Mesio Bukal 2
Bukal 2
Disto Bukal 2

Gigi 24
Mesio Bukal 3
Bukal 4
Disto Bukal 5

Gigi 25
Mesio buka 5
Bukal 5
Disto bukal 5

Gigi 26
Mesio buka 6
Bukal 6
Disto bukal 4

Gigi 27
Mesio bukal 3
Bukal 2
Disto Bukal 2

---

Resesi

Pada bukal

Gigi 17 Mesio bukal resesi 1

Gigi 16 Mesyu Bukal. Bukal dan Disto Bukal 1

Gigi 15 disto Bukal 1

---

ke bagian lingual 
probing depth

gigi 27
{disto lingual 1}
disto lingual 2
{buk} lingual 2
mesio lingual 2

Gigi 26
Disto Lingual 2
Lingual 2
Meso Lingual 4

Gigi 25
Distolingual 4
Lingual 4
Mesiolingual 4

Gigi 24
Distolingual 4
Lingual 2
Mesiolingual 2

Gigi 23
Mesiolingual 2
Lingual 2
Mesiolingual 2

Gigi 22
Distolingual 2
Lingual 2
Mesiolingual 2

Gigi 21
distolingual 2
lingual 2
mesiolingual 2.

Gigi 1-1
mesiolingual 2
lingual 2
disto lingual 2

Gigi 1-1
Mesio lingual 2
lingual 2
disto lingual 2

Gigi 1-2
Mesio lingual 2
lingual 2
disto lingual 2

Gigi 1-3
Mesio lingual 2
lingual 2
disto lingual 2

Gigi 1-4
Mesio lingual 2
lingual 2
disto lingual 2

Gigi 1 5
Mesio lingual 2
lingual 2
disto lingual 2

Gigi 1 6
mesio lingual 4
lingual 3
disto lingual 3

gigi 1-7
mesio lingual 3
lingual 3
disto lingual 2

---

Bleeding on Probing

pada bagian bukal
gigi 1-6 bukal dan mesiobukal

gigi 1-5
pada di distobukal dan bukal

gigi 2-4
mesiobukal, bukal distobukal

gigi 24
mesio bukal
bukal
disto bukal

gigi 25
mesio bukal
bukal
disto bukal

gigi 26
mesio bukal
bukal
disto bukal.

Gigi 27
mesiobukal.

---

Bleeding or probing bagian lingual

pada gigi.

Gigi 26
mesiolingual

gigi 25
distolingual
lingual
mesiolingual

gigi 24
distolingual

gigi 15
distolingual

Gigi 16
mesiolingual

---

Terdapat plaque pada semua gigi.
"""

    static let all = [
        ("student_2_ground", student_2_ground),
        ("student_1_ground", student_1_ground),
        ("dr_lucky_ground", dr_lucky_ground),
    ]
}
