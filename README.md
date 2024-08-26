# Word Property Effects on Reading Times in English as a Second Language

The study of eye movement in reading provides insights into language processing for both native (L1) and non-native (L2) speakers. Factors such as word length, frequency, and surprisal influence reading patterns in L1 readers and show a dynamic impact on L2 readers as their English proficiency changes. In particular, as the proficiency of L2 decreases, the eye movements of the readers diverge from L1 and become less sensitive to word predictability and more sensitive to word frequency [Berzak and Levy, 2023](https://direct.mit.edu/opmi/article/doi/10.1162/opmi_a_00084/116138/Eye-Movement-Traces-of-Linguistic-Knowledge-in).

The ability of large language models to process language positions them as valuable tools in cognitive models of sentence processing. Counterintuitively to NLP paradigms of "Larger is Better", [Oh and Schuler, 2023](https://arxiv.org/pdf/2212.12131) found that models with more parameters and lower perplexity often produce surprisal estimates that are less predictive of human reading times.

This study analyzes the effect of model perplexity in large transformer models and explores the impact of English proficiency on language processing. Findings from statistical analyses support [Berzak and Levy, 2023](https://direct.mit.edu/opmi/article/doi/10.1162/opmi_a_00084/116138/Eye-Movement-Traces-of-Linguistic-Knowledge-in)'s conclusions regarding L1 and L2 eye movements.

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

## Preprocessing Instructions:

After obtaining the CELER and GECO eye movement data, utilize `text-metrics-main` by [LACC Lab](https://github.com/lacclab/text-metrics). Run `text2surprisal.py` to obtain the combined CELER and Surprisal from an LLM.

For the data to be combined and inputted into the analysis R file as expected, run `merge_data.py`. This will merge the CELER and GECO data and output a `merged_data.csv` file.

We now expect the following directory structure:
```
.
├── celer
│   ├── data_v2.0
│   ├── participant_metadata
├── geco
├── surprisal_data
│   ├── merged_data.csv
.
```

## Experiments:

After obtaining the merged data, our experiments and results can be reproduced by running `surprisal_analysis.r`, originally by [Berzak et al. (2023)](https://github.com/lacclab/traces-of-ling-knowledge).
It includes the following steps:
1. Preparing the data for analysis, including filtering skipped words, nulls, etc.
2. Analysis 1: Functional Form
3. Analysis 2: Magnitude
4. Analysis 3: Interaction with L2 Proficiency

Detailed results and figures are available in our report.

Additionally, we calculate the perplexity of the LLMs in `perplexity_calc.py` and analyze the surprisal data by model in `surprisal_data_analysis.py`.

## Code Acknowledgements:

For calculating surprisal values from LLMs, we worked with given code from [LACC Lab](https://github.com/lacclab/text-metrics).

For Perplexity Calculations, we used [Huggingface Transformers - Perplexity](https://github.com/huggingface/transformers/blob/main/docs/source/en/perplexity.md).

