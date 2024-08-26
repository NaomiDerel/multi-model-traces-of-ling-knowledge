# Word Property Effects on Reading Times in English as a Second Language



## Data Installation Instructions:

1. CELER data: 

    From the [celer github](https://github.com/berzak/celer/tree/master):

   a. Obtain the [PTB-WSJ](https://catalog.ldc.upenn.edu/LDC95T7) and [BLLIP](https://catalog.ldc.upenn.edu/LDC2000T43) corpora through LDC.
   b. - Copy the `README` file of the PTB-WSJ (starts with "This is the Penn Treebank Project: Release 2 ...") to the folder `ptb_bllip_readmes/`. 
      - Copy the `README.1st` file of BLLIP (starts with "File:  README.1st ...") to the folder `ptb_bllip_readmes/`.
   c. Run `python obtain_data.py`. This will download a zipped `data_v2.0/` data folder. Extract to the top level of this directory.

2. GECO data:
   
    GECO Augmented (in the folder `geco/`). Download [GECO augmented](https://drive.google.com/file/d/1T4qgbwPkdzYmTvIqMUGJlvY-v22Ifinx/view?usp=sharing) with frequency and surprisal values and place `geco/` at the top level of this directory.


We expect the following directory structure:
```
.
├── celer
│   ├── data_v2.0
│   ├── participant_metadata
├── geco
.
```

## Pre-existing Code:

For Perplexity Calculations we used the following source:

```bibtex
@inproceedings{wolf-etal-2020-transformers,
    title = "Transformers: State-of-the-Art Natural Language Processing",
    author = "Thomas Wolf and Lysandre Debut and Victor Sanh and Julien Chaumond and Clement Delangue and Anthony Moi and Pierric Cistac and Tim Rault and Rémi Louf and Morgan Funtowicz and Joe Davison and Sam Shleifer and Patrick von Platen and Clara Ma and Yacine Jernite and Julien Plu and Canwen Xu and Teven Le Scao and Sylvain Gugger and Mariama Drame and Quentin Lhoest and Alexander M. Rush",
    booktitle = "Proceedings of the 2020 Conference on Empirical Methods in Natural Language Processing: System Demonstrations",
    month = oct,
    year = "2020",
    address = "Online",
    publisher = "Association for Computational Linguistics",
    url = "https://www.aclweb.org/anthology/2020.emnlp-demos.6",
    pages = "38--45"
}
```
