# Shared reference database for standard + online citation formats.
# Order = order of first appearance in the manuscript.

REFS = [
    # 1
    "W. A. Wulf, S. A. McKee. Hitting the memory wall: implications of the obvious. _ACM SIGARCH Computer Architecture News_. Vol. 23, pg. 20-24, 1995, https://doi.org/10.1145/216585.216588.",
    # 2
    "J. Choquette. Nvidia hopper h100 gpu: scaling performance. _IEEE Micro_. Vol. 43, pg. 9-17, 2023, https://doi.org/10.1109/MM.2023.3256796.",
    # 3
    "N. Shazeer, A. Mirhoseini, K. Maziarz, A. Davis, Q. Le, G. Hinton, J. Dean. Outrageously large neural networks: the sparsely-gated mixture-of-experts layer. _arXiv preprint_ arXiv:1701.06538, 2017, https://doi.org/10.48550/arXiv.1701.06538.",
    # 4
    "W. Fedus, B. Zoph, N. Shazeer. Switch transformers: scaling to trillion parameter models with simple and efficient sparsity. _Journal of Machine Learning Research_. Vol. 23, pg. 1-39, 2022.",
    # 5
    "S. Williams, A. Waterman, D. Patterson. Roofline: an insightful visual performance model for multicore architectures. _Communications of the ACM_. Vol. 52, pg. 65-76, 2009, https://doi.org/10.1145/1498765.1498785.",
    # 6
    "J. Backus. Can programming be liberated from the von Neumann style? a functional style and its algebra of programs. _Communications of the ACM_. Vol. 21, pg. 613-641, 1978, https://doi.org/10.1145/359576.359579.",
    # 7
    "M. D. McIlroy, E. N. Pinson, B. A. Tague. Unix time-sharing system: forward. _Bell System Technical Journal_. Vol. 57, pg. 1899-1904, 1978.",
    # 8
    "J. Liedtke. On micro-kernel construction. Proceedings of the fifteenth ACM symposium on Operating systems principles. pg. 237-250, 1995, https://doi.org/10.1145/224056.224075.",
    # 9
    "G. Klein, K. Elphinstone, G. Heiser, J. Andronick, D. Cock, P. Derrin, D. Elkaduwe, K. Engelhardt, R. Kolanski, M. Norrish, T. Sewell, H. Tuch, S. Winwood. seL4: formal verification of an OS kernel. Proceedings of the ACM SIGOPS 22nd symposium on Operating systems principles. pg. 207-220, 2009, https://doi.org/10.1145/1629575.1629596.",
    # 10
    "N. P. Jouppi, C. Young, N. Patil, D. Patterson, G. Agrawal, R. Bajwa, S. Bates, S. Bhatia, N. Boden, A. Borchers, R. Boyle, P. Cantin, C. Chao, C. Clark, J. Coriell, M. Daley, M. Dau, J. Dean, B. Gelb, T. V. Ghaemmaghami, R. Gottipati, W. Gulland, R. Hagmann, C. R. Ho, D. Hogberg, J. Hu, R. Hundt, D. Hurt, J. Ibarz, A. Jaffey, A. Jaworski, A. Kaplan, H. Khaitan, D. Killebrew, A. Koch, N. Kumar, S. Lacy, J. Laudon, J. Law, D. Le, C. Leary, Z. Liu, K. Lucke, A. Lundin, G. MacKean, A. Maggiore, M. Mahony, K. Miller, R. Nagarajan, R. Narayanaswami, R. Ni, K. Nix, T. Norrie, M. Omernick, N. Penukonda, A. Phelps, J. Ross, M. Ross, A. Salek, E. Samadiani, C. Severn, G. Sizikov, M. Snelham, J. Souter, D. Steinberg, A. Swing, M. Tan, G. Thorson, B. Tian, H. Toma, E. Tuttle, V. Vasudevan, R. Walter, W. Wang, E. Wilcox, D. H. Yoon. In-datacenter performance analysis of a tensor processing unit. Proceedings of the 44th annual international symposium on computer architecture. pg. 1-12, 2017, https://doi.org/10.1145/3079856.3080246.",
    # 11
    "J. B. Dennis. First version of a data flow procedure language. Programming Symposium. pg. 362-376, 1974, https://doi.org/10.1007/3-540-06859-7_145.",
    # 12
    "I. Barron, P. Cavill, D. May, P. Wilson. Transputer does 5 or more MIPS even when not used in parallel. _Electronics_. Vol. 56, pg. 109-115, 1983.",
    # 13
    "W. J. Dally, C. L. Seitz. Deadlock-free message routing in multiprocessor interconnection networks. _IEEE Transactions on Computers_. Vol. C-36, pg. 547-553, 1987, https://doi.org/10.1109/TC.1987.1676939.",
    # 14
    "W. J. Dally, C. L. Seitz. The torus routing chip. _Distributed Computing_. Vol. 1, pg. 187-196, 1986, https://doi.org/10.1007/BF01660031.",
    # 15
    "JEDEC Solid State Technology Association. High bandwidth memory (HBM) DRAM standard. JESD235D, 2021, https://www.jedec.org/standards-documents/docs/jesd235d.",
    # 16
    "JEDEC Solid State Technology Association. Compression attached memory module (CAMM2) common standard. JESD318, 2023, https://www.jedec.org/standards-documents/docs/jesd318.",
    # 17
    "JEDEC Solid State Technology Association. Low power double data rate 6 (LPDDR6) SDRAM standard. JESD209-6, 2025, https://www.jedec.org/standards-documents/docs/jesd209-6.",
    # 18
    "C. Lattner, M. Amini, U. Bondhugula, A. Cohen, A. Davis, J. Pienaar, R. Riddle, T. Shpeisman, N. Vasilache, O. Zinenko. MLIR: scaling compiler infrastructure for domain specific computation. 2021 IEEE/ACM International Symposium on Code Generation and Optimization (CGO). pg. 2-14, 2021, https://doi.org/10.1109/CGO51591.2021.9370308.",
    # 19
    "Message Passing Interface Forum. MPI: a message-passing interface standard, version 4.0. 2021, https://www.mpi-forum.org/docs/mpi-4.0/mpi40-report.pdf.",
    # 20
    "CERN. CERN open hardware licence version 2 - strongly reciprocal (CERN-OHL-S). 2020, https://ohwr.org/project/cernohl/wikis/Documents/CERN-OHL-version-2.",
]

def standard_ref_block():
    lines = []
    for i, r in enumerate(REFS, 1):
        lines.append(f"{i}. {r}")
    return "\n\n".join(lines)

def online(n):
    """1-based index -> ((full citation)) with leading space convention applied by caller."""
    return f"(({REFS[n-1]}))"

def scite(*nums):
    """LaTeX superscript citation(s)."""
    return "\\textsuperscript{" + ",".join(str(n) for n in nums) + "}"

def ocite(*nums):
    """Online double-paren citations with plain comma separators (user does superscript comma in Word)."""
    parts = [online(n) for n in nums]
    # Join with ), (( pattern - Word find-replace turns comma to superscript
    if len(parts) == 1:
        return " " + parts[0]
    return " " + "\u00b9COMMA\u00b9".join(parts)  # placeholder replaced later
