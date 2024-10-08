# install libraries (run all the following in terminal)

# install.packages("tidyverse")
# install.packages("dplyr")
# install.packages("ggplot2")
# install.packages("ggpubr")
# install.packages("broom")
# install.packages("mgcv")
# install.packages("gridExtra")
# install.packages("cowplot")
# install.packages("rsample")
# install.packages("JuliaCall")


library(tidyverse)
library(dplyr)
library(ggplot2)
library(ggpubr)
library(broom)
library(mgcv)
library(gridExtra)
library(grid)
library(cowplot)
library(rsample)
library(JuliaCall)
library(lme4)
library(readr)

library(vroom)

set.seed(214)


CELER_PATH = "celer/" #local path to CELER dataset (NOTE: changed)
# Path to the new file containing surprisal from new language models
SURP_PATH = "surprisal_data/"
DATA_SUBSET = "ALL" # "ALL" all, 1 v1, 2 participants new to v2
NORM_TIMES = FALSE # Z normalize reading times
BY_L1 = FALSE # for Analysis 1

#Thresholds used for GAM plotting (models fitted on all the data)
THRESH_SURP = 20
THRESH_FREQ = 25
THRESH_WL = 14


# GAM
BOOTSTRAP_TIMES = 1 # number of times to repeat bootrstrapping for GAM fits 
K = 20 # GAM parameter
STEP = 0.1 #interval for prediction from GAM models

ENGLISH_TEST = "MichiganLG"  #"Comprehension_individual" 

LM_DEFAULT = "SURP_GPT2"
# Change the default language model here
# The three language models are: 
# "EleutherAI.pythia.70m_Surprisal", 
# "EleutherAI.pythia.160m_Surprisal", 
# "EleutherAI.pythia.410m_Surprisal"
LM_DEFAULT = "EleutherAI.pythia.70m_Surprisal"
FREQUENCY_DEFAULT = "FREQ_SUBTLEX"
OOV_DEFAULT = "OOV_SUBTLEX"

word_properties <- c("FREQUENCY", "SURPRISAL", "WORD_LENGTH")
rts <- c("FIRST_FIXATION", "GAZE_DURATON", "TOTAL_FIXATION")
# rts <- c("GAZE_DURATION")
colors <- c("L1" = "red", "L2" = "blue")
l1_colors <- c("English" = "red", 
               "Chinese" = "green", 
               "Japanese" = "blue", 
               "Spanish" = "gold", 
               "Portuguese" = "orange", 
               "Arabic" = "purple")

# Mixed Effects models in Julia
j<-julia_setup() # Setup Julia Integration in R
# j$eval('using Pkg; Pkg.add("MixedModels")')
j$library("MixedModels")
# Function to Run Mixed-Effects Models
# report: The data frame containing the data to be modeled.
# mx_formula: The formula for the mixed-effects model.
run_mixed_effects_julia <- function(report, mx_formula){
    julia_assign("report", report)
    julia_assign("formula", formula(mx_formula))
    result <- julia_eval("fit(LinearMixedModel, formula, report)")
    return(result)
}

# These functions are used to calculate the standard error of the mean, 
# the upper bound, and the lower bound of a 95% confidence interval 
# for a given numeric vector x.
sem <- function(x){sd(x)/sqrt(length(x))}
upper <- function(x){mean(x)+1.96*sem(x)}
lower <- function(x){mean(x)-1.96*sem(x)}

# ```


### Read and preprocess CELER
print("Preprocessing CELER data")
#read fixation report
# report_ia <-read.table(paste0(CELER_PATH, "data_v2.0/sent_ia.tsv"), header = TRUE, quote = "", sep = "\t")
# Read the new data table
report_ia <-read.table(paste0(SURP_PATH, "merge_data.tsv"), header = TRUE, quote = "", sep = "\t")
# report_ia <- read_tsv(paste0(SURP_PATH, "merge_output4.tsv"))

#subset to v1.0 or participants new to v2.0
if (DATA_SUBSET != "ALL") {
    report_ia <- report_ia %>% filter(dataset_version == DATA_SUBSET)
}

#read participant metadata
metadata <- read.table(paste0(CELER_PATH, "participant_metadata/metadata.tsv"), 
                       header = TRUE, quote = "", sep = "\t", row.names="List") %>%
            mutate(English = as.factor(ifelse(L1 == "English", "L1", "L2")))

#note: this info can also be computed off of the report (answered_correctly field)
comprehension_shared <- read.table(paste0(CELER_PATH, "participant_metadata/test_scores/comprehension/total-scores-shared.tsv"), 
                            header = TRUE, quote = "", sep = "\t", row.names="list")
comprehension_individual <- read.table(paste0(CELER_PATH, "participant_metadata/test_scores/comprehension/total-scores-individual.tsv"), 
                        header = TRUE, quote = "", sep = "\t", row.names="list")
metadata <- metadata %>% mutate(Comprehension_shared = comprehension_shared$answered_correctly,
                                Comprehension_individual = comprehension_individual$answered_correctly,
                                Comprehension = (Comprehension_shared + Comprehension_individual) / 2)

#SUBJECT and normalized word as factor
# process the data...
report_ia <- report_ia %>% rename(SUBJECT = list) %>%
                           mutate(SUBJECT = as.factor(SUBJECT),
                                  WORD_NORM = as.factor(WORD_NORM))

report_ia <- report_ia %>% rename(WORD_LENGTH = WORD_LEN,
                                  FIRST_FIXATION = IA_FIRST_FIXATION_DURATION,
                                  GAZE_DURATION = IA_FIRST_RUN_DWELL_TIME,
                                  TOTAL_FIXATION = IA_DWELL_TIME) %>%
                            #set unfixated word reading times to 0
                            mutate( FIRST_FIXATION = as.integer(replace(as.character(FIRST_FIXATION), FIRST_FIXATION == ".", "0")),
                                   GAZE_DURATION = as.integer(replace(as.character(GAZE_DURATION), GAZE_DURATION == ".", "0")))
                          
#add L1 and proficiency information form metadata
report_ia <- report_ia %>% mutate(MPT = map_dbl(SUBJECT, function(x){metadata[toString(x), ENGLISH_TEST]}),
                                  L1 = as.factor(unlist(map(SUBJECT, function(x){metadata[toString(x),"L1"]}))),
                                  English = as.factor(ifelse(L1 == "English", "L1", "L2")))

#set default frequency and suprisal
report_ia <- report_ia %>% mutate_("FREQUENCY" = FREQUENCY_DEFAULT,
                                   "OOV" = OOV_DEFAULT) 
report_ia <- gather_(report_ia, "lm", "SURPRISAL", c('SURP_GPT2', 'SURP_LSTM', 'SURP_KENLM', 'EleutherAI.pythia.70m_Surprisal'), factor_key = TRUE)
report_ia <- report_ia %>% filter(lm == LM_DEFAULT)

#word properties of the previous word
report_ia <- report_ia %>%  mutate(SURPRISAL_prev1 = lag(SURPRISAL),
                                   FREQUENCY_prev1 = lag(FREQUENCY),
                                   WORD_LENGTH_prev1 = lag(WORD_LENGTH),
                                   OOV_prev1 = lag(OOV)) 

#remove first & last words, words with punctuation, numbers
report_ia <- report_ia %>% group_by(lm, SUBJECT, trial) %>% 
                           slice(2:(n()-1)) %>% ungroup() #first and last word in the sentence
report_ia <- report_ia %>% filter(!grepl("NUM", WORD_NORM), #numbers
                                  !grepl('^[[:punct:]]|[[:punct:]]$', IA_LABEL)) #punctuation

#remove out of vocabulary words
report_ia <- report_ia %>% filter(OOV == 0, OOV_prev1 == 0)

#remove skips
report_ia <- report_ia %>% filter(TOTAL_FIXATION > 0)

report_ia <- gather(report_ia, "fix_measure", "RT", 
                    c('FIRST_FIXATION', 'GAZE_DURATION', 'TOTAL_FIXATION'), 
                    # c('GAZE_DURATION'), 
                    factor_key = TRUE) 

#Z score reading times
if (NORM_TIMES == TRUE){
      report_ia = report_ia %>% group_by(lm, fix_measure, shared_text, SUBJECT) %>% 
                                mutate_at(c('RT'), scale) %>% ungroup()
}

#Individual regime
# What exactly does MPT mean? 
report_ia <- report_ia %>% filter(shared_text == 0)

# Notice: This step removed NaN values from the dataset (if any)
report_ia <- report_ia[!is.nan(report_ia$SURPRISAL) & !is.nan(report_ia$SURPRISAL_prev1), ]

report_ia <- report_ia %>% group_by(shared_text, lm, fix_measure) %>%
                             mutate(SURPRISAL_c = SURPRISAL-mean(SURPRISAL),
                                    FREQUENCY_c = FREQUENCY-mean(FREQUENCY),
                                    WORD_LENGTH_c = WORD_LENGTH - mean(WORD_LENGTH),
                                    SURPRISAL_prev1_c = SURPRISAL_prev1 - mean(SURPRISAL_prev1),
                                    FREQUENCY_prev1_c = FREQUENCY_prev1 - mean(FREQUENCY_prev1),
                                    WORD_LENGTH_prev1_c = WORD_LENGTH_prev1 - mean(WORD_LENGTH_prev1),
                                    SURPRISAL_z = scale(SURPRISAL),
                                    FREQUENCY_z = scale(FREQUENCY),
                                    WORD_LENGTH_z = scale(WORD_LENGTH),
                                    SURPRISAL_prev1_z = scale(SURPRISAL_prev1),
                                    FREQUENCY_prev1_z = scale(FREQUENCY_prev1),
                                    WORD_LENGTH_prev1_z = scale(WORD_LENGTH_prev1)) %>% ungroup()

report_ia <- report_ia %>% group_by(shared_text, lm, fix_measure, SUBJECT) %>% 
                             mutate(SURPRISAL_c_subj = SURPRISAL - mean(SURPRISAL),
                                    FREQUENCY_c_subj = FREQUENCY - mean(FREQUENCY),
                                    WORD_LENGTH_c_subj = WORD_LENGTH - mean(WORD_LENGTH),
                                    SURPRISAL_prev1_c_subj = SURPRISAL_prev1 - mean(SURPRISAL_prev1),
                                    FREQUENCY_prev1_c_subj = FREQUENCY_prev1 - mean(FREQUENCY_prev1),
                                    WORD_LENGTH_prev1_c_subj = WORD_LENGTH_prev1 - mean(WORD_LENGTH_prev1),
                                    SURPRISAL_z_subj = scale(SURPRISAL),
                                    FREQUENCY_z_subj = scale(FREQUENCY),
                                    WORD_LENGTH_z_subj = scale(WORD_LENGTH),
                                    SURPRISAL_prev1_z_subj = scale(SURPRISAL_prev1),
                                    FREQUENCY_prev1_z_subj = scale(FREQUENCY_prev1),
                                    WORD_LENGTH_prev1_z_subj = scale(WORD_LENGTH_prev1)) %>% ungroup()

report_ia <- report_ia %>% mutate(MPT = replace(MPT, is.na(MPT), 50))
report_ia <- report_ia %>% group_by(shared_text, lm, fix_measure, English) %>% 
                           mutate(MPT_c = MPT-mean(MPT))

report_ia <- report_ia %>% mutate(SURPRISAL_SQ = SURPRISAL^2,
                                  FREQUENCY_SQ = FREQUENCY^2,
                                  WORD_LENGTH_SQ = WORD_LENGTH^2)

## threshold predictor values (for statistical tests on curves)
report_ia_thresh = data.frame(report_ia)
report_ia_thresh <- report_ia_thresh %>% group_by(lm) %>% 
                               filter(SURPRISAL <= THRESH_SURP,
                                      FREQUENCY <= THRESH_FREQ, 
                                      WORD_LENGTH <= THRESH_WL)%>% ungroup()


### Analysis 1: GAMs for L1 and L2
print("Fitting GAMs for L1 and L2")
# if (!is.finite(pred_range$FREQUENCY[1])) {
#     pred_range$FREQUENCY[1] <- 1  # Replace with a default value
# }

pred_range <- list(FREQUENCY = c(round(min(report_ia$FREQUENCY)), THRESH_FREQ), 
                   SURPRISAL = c(0, THRESH_SURP),
                   WORD_LENGTH = c(1, THRESH_WL))
nd_surp <- data.frame(SURPRISAL = seq(pred_range$SURPRISAL[1], pred_range$SURPRISAL[2], by = STEP), 
                      SURPRISAL_prev1 = seq(pred_range$SURPRISAL[1], pred_range$SURPRISAL[2], by = STEP), 
                      FREQUENCY = 0, FREQUENCY_prev1 = 0, WORD_LENGTH = 0, WORD_LENGTH_prev1 = 0, SUBJECT = 0)
nd_freq <- data.frame(SURPRISAL=0, SURPRISAL_prev1 = 0,
                      FREQUENCY = seq(pred_range$FREQUENCY[1], pred_range$FREQUENCY[2], by = STEP),  
                      FREQUENCY_prev1 = seq(pred_range$FREQUENCY[1], pred_range$FREQUENCY[2], by = STEP), 
                      WORD_LENGTH = 0, WORD_LENGTH_prev1 = 0, SUBJECT = 0)
nd_wl <- data.frame(SURPRISAL = 0, SURPRISAL_prev1 = 0, FREQUENCY = 0, FREQUENCY_prev1=0,
                      WORD_LENGTH = seq(pred_range$WORD_LENGTH[1], pred_range$WORD_LENGTH[2], by = STEP), 
                      WORD_LENGTH_prev1 = seq(pred_range$WORD_LENGTH[1], pred_range$WORD_LENGTH[2], by = STEP), SUBJECT = 0)
nd <- list(SURPRISAL = nd_surp, FREQUENCY = nd_freq, WORD_LENGTH = nd_wl)


new_data_from_df <- function(report){
  nd_s <- data.frame(SURPRISAL = report$SURPRISAL, SURPRISAL_prev1 = report$SURPRISAL_prev1, 
                     FREQUENCY = 0, FREQUENCY_prev1 = 0, WORD_LENGTH = 0, WORD_LENGTH_prev1 = 0) 
  nd_f <- data.frame(SURPRISAL=0, SURPRISAL_prev1 = 0,
                      FREQUENCY = report$FREQUENCY, FREQUENCY_prev1 = report$FREQUENCY_prev1,
                      WORD_LENGTH = 0, WORD_LENGTH_prev1 = 0)
  nd_wl <- data.frame(SURPRISAL = 0, SURPRISAL_prev1 = 0, FREQUENCY = 0, FREQUENCY_prev1 = 0,
                      WORD_LENGTH = report$WORD_LENGTH, WORD_LENGTH_prev1 = report$WORD_LENGTH_prev1)
  nd_all <- list(SURPRISAL = nd_s, FREQUENCY = nd_f, WORD_LENGTH = nd_wl)
  return(nd_all) 
}

nd_all_words <- new_data_from_df(report_ia)

predict_gam <- function(m, word_property, new_data, start_zero){
  term_str = paste("s(", word_property, ")", sep="")
  term_prev_str = paste("s(", word_property, "_prev1)", sep="")
  pred <- predict(m, new_data[[word_property]], terms=c(term_str, term_prev_str), type="terms")
  if (start_zero == TRUE) {
  pred <- sweep(pred, 2, pred[which.min(new_data[[word_property]][[word_property]]),])
  }
  result <- data.frame(word_property = word_property, 
                       x = new_data[[word_property]][[word_property]], 
                       current = pred[,term_str],
                       previous = pred[,term_prev_str])
  result <- result %>% mutate(total = current +  previous)
  return(result)
}

# Bootstrapping method of Smith and Levy 2013. The code (fit_gam_bootstraps and run_gam_bootstraps) is based on  https://github.com/wilcoxeg/neural-networks-read-times/blob/master/scripts/analysis.Rmd
fit_gam_bootstraps <- function(bootstrap_sample, key){
  # rsplit$data contains the original entire dataset.
  df = bootstrap_sample$data
  # as.integer.rsplit returns the indices of the examples which are in-sample.
  # convert this to a count vector, with dimension N (total dataset rows)
  weights = tabulate(as.integer(bootstrap_sample), nrow(df))
  # Fitting Model for SURPRISAL
  m_surp <- bam(RT ~  s(SURPRISAL, bs = "cr", k = K) + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) +
                      te(FREQUENCY, WORD_LENGTH, bs = "cr") +
                      te(FREQUENCY_prev1, WORD_LENGTH_prev1, bs = "cr") +
                      #random effects      
                      s(SUBJECT, bs = "re") +
                      s(SUBJECT, SURPRISAL, bs = "re") +
                      te(SUBJECT, FREQUENCY, WORD_LENGTH, bs = "re"),
                      data = df, weights = weights) 
  # Fitting Model for FREQUENCY and WORD_LENGTH
  m_freq_wl <- bam(RT ~  s(SURPRISAL, bs = "cr", k = K) + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) +
                      s(FREQUENCY, bs = "cr", k = K) + 
                      s(FREQUENCY_prev1, bs = "cr", k = K) +
                      s(WORD_LENGTH, bs = "cr") +
                      s(WORD_LENGTH_prev1, bs = "cr") +
                      #random effects
                      s(SUBJECT, bs = "re") +
                      s(SUBJECT, SURPRISAL, bs = "re") +
                      s(SUBJECT, FREQUENCY, bs = "re") +
                      s(SUBJECT, WORD_LENGTH, bs = "re"),
                      data = df, weights = weights)
  pred_surp <- predict_gam(m_surp, "SURPRISAL", nd, start_zero = TRUE)
  pred_freq <- predict_gam(m_freq_wl, "FREQUENCY", nd, start_zero = TRUE)
  pred_word_len <- predict_gam(m_freq_wl, "WORD_LENGTH", nd, start_zero = TRUE)
  result <- bind_rows(pred_surp, pred_freq, pred_word_len)
return(result)
}

#fit a gam, no bootstrapping, predict for all words in corpus
fit_gam_subj <- function(df){
  m_surp <- bam(RT ~  s(SURPRISAL, bs = "cr", k = K) + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) +
                      te(FREQUENCY, WORD_LENGTH, bs = "cr") +
                      te(FREQUENCY_prev1, WORD_LENGTH_prev1, bs = "cr"),
                      data = df) 
  # print(summary(m_surp))
  m_freq_wl <- bam(RT ~  s(SURPRISAL, bs = "cr", k = K) + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) +
                      s(FREQUENCY, bs = "cr", k = K) + 
                      s(FREQUENCY_prev1, bs = "cr", k = K) +
                      s(WORD_LENGTH, bs = "cr") +
                      s(WORD_LENGTH_prev1, bs = "cr"),
                      data = df)
  pred_surp <- predict_gam(m_surp, "SURPRISAL", nd_all_words, start_zero = TRUE) 
  pred_freq <- predict_gam(m_freq_wl, "FREQUENCY", nd_all_words, start_zero = TRUE)
  pred_word_len <- predict_gam(m_freq_wl, "WORD_LENGTH", nd_all_words, start_zero = TRUE)
  all_pred <- bind_rows(pred_surp, pred_freq, pred_word_len) %>% ungroup
  slowdowns <- all_pred %>% group_by(word_property) %>%
                            summarize(slowdown_current = mean(current),
                            slowdown_previous = mean(previous),
                            slowdown_total = mean(total))
return(slowdowns)
}

# Like fit_gam_subj, but returns predictions instead of slowdowns
fit_gam_subj_our <- function(df){
  # Fit the GAM models
  m_surp <- bam(RT ~  s(SURPRISAL, bs = "cr", k = K) + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) +
                      te(FREQUENCY, WORD_LENGTH, bs = "cr") +
                      te(FREQUENCY_prev1, WORD_LENGTH_prev1, bs = "cr"),
                      data = df) 
  
  m_freq_wl <- bam(RT ~  s(SURPRISAL, bs = "cr", k = K) + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) +
                      s(FREQUENCY, bs = "cr", k = K) + 
                      s(FREQUENCY_prev1, bs = "cr", k = K) +
                      s(WORD_LENGTH, bs = "cr") +
                      s(WORD_LENGTH_prev1, bs = "cr"),
                      data = df)
  
  # Create a new data frame with all required variables
  # Here, nd_all_words should be a data frame that includes SURPRISAL, SURPRISAL_prev1, FREQUENCY, WORD_LENGTH, etc.
  nd_all_words <- df  # Or modify to be a subset or different dataset as needed
  
  # Generate predictions with standard errors
  pred_surp <- predict(m_surp, newdata = nd_all_words, se.fit = TRUE, type = "response")
  pred_freq <- predict(m_freq_wl, newdata = nd_all_words, se.fit = TRUE, type = "response")
  pred_word_len <- predict(m_freq_wl, newdata = nd_all_words, se.fit = TRUE, type = "response")
  
  # Combine the predictions and standard errors into a dataframe
  all_pred <- data.frame(
    word_property = rep(c("SURPRISAL", "FREQUENCY", "WORD_LENGTH"), each = nrow(nd_all_words)),
    x = c(nd_all_words$SURPRISAL, nd_all_words$FREQUENCY, nd_all_words$WORD_LENGTH),
    current = c(pred_surp$fit, pred_freq$fit, pred_word_len$fit),
    se.fit_current = c(pred_surp$se.fit, pred_freq$se.fit, pred_word_len$se.fit),
    previous = c(NA, NA, NA), # Modify if necessary
    se.fit_previous = c(NA, NA, NA) # Modify if necessary
  )
  
  return(all_pred)
}



# Performs bootstrapping on the dataset to fit Generalized Additive Models (GAMs)
# and then calculates confidence intervals for the predicted effects.
run_gam_bootstraps <- function(df, key, alpha=0.05) {
  # Bootstrap-resample data
  boot_models <- df %>% bootstraps(times=BOOTSTRAP_TIMES) %>% 
                        # Fit a GAM and get predictions for each sample
                        mutate(smoothed=map(splits, fit_gam_bootstraps))
  # Extract mean and 5% and 95% percentile y-values for each surprisal value
  result = boot_models %>% 
           unnest(smoothed) %>%
           select(word_property, x, current, previous) %>% 
           group_by(word_property, x) %>% 
           summarise(current_lower=quantile(current, alpha / 2), 
                     current_upper=quantile(current, 1 - alpha / 2),
                     previous_lower=quantile(previous, alpha / 2), 
                     previous_upper =quantile(previous, 1 - alpha / 2),
                     current=mean(current),
                     previous=mean(previous)) %>% 
           ungroup()
  return(result)
}

################################################
# No bootstrapping
# Run GAM with confidence intervals on all the data
run_gam_prediction_with_ci <- function(df, key, alpha = 0.05) {
  # Fit the GAM models without bootstrapping
  all_pred <- fit_gam_subj_our(df)
  
  # Calculate confidence intervals using the standard errors
  
  z_value <- qnorm(1 - alpha / 2)
  
  all_pred <- all_pred %>%
    mutate(current_lower = current - z_value * se.fit_current,
           current_upper = current + z_value * se.fit_current,
           previous_lower = previous - z_value * se.fit_previous,
           previous_upper = previous + z_value * se.fit_previous)

  return(all_pred)
}


################################################

#replace s term with a linear and a quadratic terms and test for significance of the quadratic term
test_quadratic_coef <- function(df){
  m_surp  <- bam(RT ~ SURPRISAL + 
                      SURPRISAL_SQ + 
                      s(SURPRISAL_prev1, bs = "cr", k = K) + 
                      te(FREQUENCY, WORD_LENGTH, bs = "cr") + 
                      te(FREQUENCY_prev1, WORD_LENGTH_prev1, bs = "cr") +
                      #random effects   
                      s(SUBJECT, bs = "re") +
                      s(SUBJECT, SURPRISAL, bs = "re") +
                      s(SUBJECT, SURPRISAL_SQ, bs = "re") +
                      te(SUBJECT, FREQUENCY, WORD_LENGTH, bs = "re"),
                 data = df)
  m_freq <- bam(RT ~ s(SURPRISAL, bs = "cr", k = K) + 
                     s(SURPRISAL_prev1, bs = "cr", k = K) +
                     FREQUENCY + 
                     FREQUENCY_SQ + 
                     s(FREQUENCY_prev1, bs = "cr", k = K) +
                     s(WORD_LENGTH, bs = "cr") + 
                     s(WORD_LENGTH_prev1, bs = "cr") +
                     #random effects
                     s(SUBJECT, bs = "re") +
                     s(SUBJECT, SURPRISAL, bs = "re") +
                     s(SUBJECT, FREQUENCY, bs = "re") +
                     s(SUBJECT, FREQUENCY_SQ, bs = "re") +
                     s(SUBJECT, WORD_LENGTH, bs = "re"),
                data = df)
  m_wl <- bam(RT ~ s(SURPRISAL, bs = "cr", k = K) + 
                   s(SURPRISAL_prev1, bs = "cr", k = K) +
                   s(FREQUENCY, bs = "cr", k = K) + 
                   s(FREQUENCY_prev1, bs = "cr", k = K) +
                   WORD_LENGTH + 
                   WORD_LENGTH_SQ + 
                   s(WORD_LENGTH_prev1, bs = "cr") +
                   #random effects
                   s(SUBJECT, bs = "re") +
                   s(SUBJECT, SURPRISAL, bs = "re") +
                   s(SUBJECT, FREQUENCY, bs = "re") +
                   s(SUBJECT, WORD_LENGTH, bs = "re") +
                   s(SUBJECT, WORD_LENGTH_SQ, bs = "re"),
                      data = df) 
  
  coef_lin = c(summary(m_freq)$p.coef["FREQUENCY"], summary(m_surp)$p.coef["SURPRISAL"], summary(m_wl)$p.coef["WORD_LENGTH"])
  coef_sq = c(summary(m_freq)$p.coef["FREQUENCY_SQ"], summary(m_surp)$p.coef["SURPRISAL_SQ"], summary(m_wl)$p.coef["WORD_LENGTH_SQ"])
  
  lin_sig = c(summary(m_freq)$p.pv["FREQUENCY"], summary(m_surp)$p.pv["SURPRISAL"], summary(m_wl)$p.pv["WORD_LENGTH"])
  quad_sig = c(summary(m_freq)$p.pv["FREQUENCY_SQ"], summary(m_surp)$p.pv["SURPRISAL_SQ"], summary(m_wl)$p.pv["WORD_LENGTH_SQ"])
  
  formula_quad = c(paste(round(coef_lin[1],2),"x ",round(coef_sq[1],2),"x^2", sep=""), paste(round(coef_lin[2],2),"x ",round(coef_sq[2],2),"x^2", sep=""), paste(round(coef_lin[3],2),"x ",round(coef_sq[3],2),"x^2", sep=""))
  quad_sig_stars = symnum(quad_sig, corr = FALSE, na = FALSE, cutpoints = c(0, 0.001, 0.01, 0.05, 1), 
                          symbols = c("***", "**", "*", "(.)"))
  lin_sig_stars = symnum(lin_sig, corr = FALSE, na = FALSE, cutpoints = c(0, 0.001, 0.01, 0.05, 1), 
                          symbols = c("***", "**", "*", "(.)"))
  
  word_property = c("FREQUENCY", "SURPRISAL", "WORD_LENGTH")
  return(data.frame(word_property, coef_lin, coef_sq, lin_sig, quad_sig, lin_sig_stars, quad_sig_stars, formula_quad))
}

# Calculate the quadratic prediction for the GAM
get_quad_y <- function(results_df, quad_df){
  model_row = filter(quad, lm == unique(results_df$lm), fix_measure == unique(results_df$fix_measure), 
  English == unique(results_df$English), word_property == unique(results_df$word_property))
  pred = results_df$x*model_row$coef_lin + ((results_df$x)^2)*model_row$coef_sq
  pred = pred - pred[1]
  results_df$`x+x^2` = pred  
  
  return(results_df)
}

### Stop Here - next analysis runs in a couple hours for 1 bootstrap ###

print("Calculate Results")

# Change Run type to all data instead of bootstrapping
if (BY_L1 == TRUE){
  # results <- report_ia %>% group_by(lm, fix_measure, L1) %>% group_modify(run_gam_bootstraps)
  results <- report_ia %>% group_by(lm, fix_measure, L1) %>% group_modify(run_gam_prediction_with_ci)
  quad <- report_ia_thresh %>% group_by(lm, fix_measure, L1) %>% do(test_quadratic_coef(.))
} else{
  # results <- report_ia %>% group_by(lm, fix_measure, English) %>% group_modify(run_gam_bootstraps)
  results <- report_ia %>% group_by(lm, fix_measure, English) %>% group_modify(run_gam_prediction_with_ci)
  quad <- report_ia_thresh %>% group_by(lm, fix_measure, English) %>% do(test_quadratic_coef(.))
  results <- results %>% group_by(lm, fix_measure, English, word_property) %>% do(get_quad_y(., quad))
}
print("Results calculated")
# Transform the results data frame into a long format, 
# which makes it easier to work with for plotting or further analysis
results_long <- results %>% gather("word", "y", c("current", "previous")) %>%
            gather("upper", "y_upper", c("current_upper", "previous_upper")) %>%
            gather("lower", "y_lower", c("current_lower", "previous_lower")) %>%
            filter((substr(word,1,7) == substr(upper,1,7)) &
                  (substr(word,1,7) == substr(lower,1,7)))


### Plot GAMs
# <!-- ```{r,fig.width=10,fig.height=10} -->
print("Plotting GAMs")
plot_density <- function(df, key){
    p<- ggplot() +
        theme_bw(base_size = 30) + #
        geom_area(data = df, aes(x=x, y=y), color = "purple", fill = "purple", alpha = 0.1) +
        facet_wrap(~word_property, dir = "h", scales = "free") +
        labs(title = NULL, x = NULL, y = NULL) + 
        theme(plot.title = element_text(size = 30, hjust = 0.5))
    return(p)  
}

get_d_points = function(df, lm, fix_measure, word_property){
  if(word_property == "WORD_LENGTH"){
      h = hist(df$val, plot = FALSE)
      x = head(h$breaks, -1)
      y = h$counts/sum(h$counts)
  }
  else{
        x = density(df$val)$x
        y = density(df$val)$y
  }
  return(data.frame(x, y))
}

# Remove rows where either SURPRISAL or SURPRISAL_prev1 is NaN
get_d_points_nans <- function(df, lm, fix_measure, word_property) {
  # Remove NA values from df$val
  df <- df %>% filter(!is.na(val))

  if (word_property == "WORD_LENGTH") {
    if (nrow(df) == 0) {
      # Handle case where df is empty after filtering NA values
      return(data.frame(x = numeric(0), y = numeric(0)))
    }
    h <- hist(df$val, plot = FALSE)
    x <- head(h$breaks, -1)
    y <- h$counts / sum(h$counts)
  } else {
    if (nrow(df) == 0) {
      # Handle case where df is empty after filtering NA values
      return(data.frame(x = numeric(0), y = numeric(0)))
    }
    density_result <- density(df$val)
    x <- density_result$x
    y <- density_result$y
  }

  return(data.frame(x, y))
}

trim = function(df){
  word_prop = unique(df$word_property)
  df <- filter(df, x > pred_range[[word_prop]][1], x < pred_range[[word_prop]][2])
  return(df)
}

report_ia_long = gather(report_ia, key = "word_property", value = "val", all_of(word_properties))

# Get the density points
density_data = report_ia_long %>% filter(fix_measure == "TOTAL_FIXATION") %>%
  group_by(lm, word_property) %>%
    do({get_d_points_nans(., unique(.$lm), unique(.$fix_measure), unique(.$word_property))}) %>%
  do(trim(.)) %>%
  ungroup()
  
density_plots <- density_data %>% group_by(lm) %>% group_map(plot_density)

plot_gam_by_l1 <- function(data, key, quad) { #
  data_current = filter(data, word == "current")
  quad_data_english = filter(quad, lm == key[[1]], L1 == "English")
  quad_data_arabic = filter(quad, lm == key[[1]], L1 == "Arabic")
  quad_data_chinese = filter(quad, lm == key[[1]], L1 == "Chinese")
  quad_data_japanese = filter(quad, lm == key[[1]], L1 == "Japanese")
  quad_data_portuguese = filter(quad, lm == key[[1]], L1 == "Portuguese")
  quad_data_spanish = filter(quad, lm == key[[1]], L1 == "Spanish")
  
  ylabel = ifelse(NORM_TIMES == TRUE, "Slowdown", "Slowdown (ms)")
  p <- ggplot() +
  theme_bw(base_size = 30) +
  geom_line(data = data_current, aes(x=x, y=y, col = L1))  +
  geom_text(data = quad_data_english, aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=0, size = 12, color = l1_colors["English"]) +  
  geom_text(data = quad_data_arabic,  aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=-2, size = 12, color = l1_colors["Arabic"]) +  
  geom_text(data = quad_data_arabic,  aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=-4, size = 12, color = l1_colors["Chinese"]) +  
  geom_text(data = quad_data_arabic,  aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=-6, size = 12, color = l1_colors["Japanese"]) +  
  geom_text(data = quad_data_arabic,  aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=-8, size = 12, color = l1_colors["Portuguese"]) +  
  geom_text(data = quad_data_arabic,  aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=-10, size = 12, color = l1_colors["Spanish"]) +  
  
  geom_ribbon(data = data_current, aes(x=x, ymin=y_lower, ymax=y_upper, fill=L1, color=NA), alpha = 0.2) +
  facet_wrap(fix_measure ~ word_property, scales = 'free') + 
  scale_color_manual(values = colors) +
  scale_fill_manual(values = colors)  +
  theme(plot.title = element_text(size = 30, hjust = 0.5)) + 
    ylab(ylabel) + xlab(NULL)
  return(p)
}

plot_gam <- function(data, key, quad) { #
  #data = filter(data, word == "current")
  quad_data_l2 = filter(quad, lm == key[[1]], English == "L2")
  quad_data_l1 = filter(quad, lm == key[[1]], English == "L1")
  ylabel = ifelse(NORM_TIMES == TRUE, "Slowdown", "Slowdown (ms)")
  p <- ggplot() +
  theme_bw(base_size = 30) +
  geom_line(data = data, aes(x=x, y=y, col = English, linetype = word))  + #linetype = term / word (in which case commend out first line)
  geom_text(data = quad_data_l1, aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=0, size = 12, color = colors["L1"])+  
  geom_text(data = quad_data_l2, aes(x = -Inf, y= Inf, label=quad_sig_stars), vjust=1.1, hjust=-2, size = 12, color = colors["L2"])+ 
  geom_ribbon(data = data, aes(x=x, ymin=y_lower, ymax=y_upper, fill=English, alpha = word)) + #current word only, alpha = 0.3 outside the aes
  facet_wrap(fix_measure ~ word_property, scales = "free") + #scales = 'free' 
  scale_color_manual(values = colors) +
  scale_fill_manual(values = colors)  +
  scale_linetype_manual(values = c("solid", "dashed"), guide = guide_legend(override.aes=list(fill=NA, col = "black")))  +
  scale_alpha_manual(values = c(0.3, 0.1))  + #current word only, comment out
  theme(plot.title = element_text(size = 30, hjust = 0.5)) + 
    ylab(ylabel) + xlab(NULL)
  return(p)
}

# Plot till the 90th percentile of surprisal
plot_gam_90 <- function(data, key, quad) {
  # Calculate the 95th percentile of the SURPRISAL
  surprisal_95th <- quantile(data$x[data$word_property == "SURPRISAL"], 0.90)
  
  # Filter the data to only include values up to the 95th percentile
  data_filtered <- data %>%
    filter(word_property != "SURPRISAL" | (word_property == "SURPRISAL" & x <= surprisal_95th))
  
  quad_data_l2 <- filter(quad, lm == key[[1]], English == "L2")
  quad_data_l1 <- filter(quad, lm == key[[1]], English == "L1")
  ylabel <- ifelse(NORM_TIMES == TRUE, "Slowdown", "Slowdown (ms)")
  
  p <- ggplot() +
    theme_bw(base_size = 30) +
    geom_line(data = data_filtered, aes(x = x, y = y, col = English, linetype = word)) +
    geom_text(data = quad_data_l1, aes(x = -Inf, y = Inf, label = quad_sig_stars), vjust = 1.1, hjust = 0, size = 12, color = colors["L1"]) +  
    geom_text(data = quad_data_l2, aes(x = -Inf, y = Inf, label = quad_sig_stars), vjust = 1.1, hjust = -2, size = 12, color = colors["L2"]) + 
    geom_ribbon(data = data_filtered, aes(x = x, ymin = y_lower, ymax = y_upper, fill = English, alpha = word)) +
    facet_wrap(fix_measure ~ word_property, scales = "free") +
    scale_color_manual(values = colors) +
    scale_fill_manual(values = colors) +
    scale_linetype_manual(values = c("solid", "dashed"), guide = guide_legend(override.aes = list(fill = NA, col = "black"))) +
    scale_alpha_manual(values = c(0.3, 0.1)) +
    theme(plot.title = element_text(size = 30, hjust = 0.5)) +
    ylab(ylabel) + xlab(NULL)
  
  return(p)
}

plot_gam_smooth <- function(data, key, quad) {
  # Ensure English is a factor
  # data$English <- as.factor(data$English)

  # Remove any rows with NA or non-finite values in key columns
  data <- data %>% filter(is.finite(x), is.finite(y), is.finite(y_lower), is.finite(y_upper))

  # Check if data$x has valid values after filtering
  if (nrow(data) == 0) {
    stop("No valid data in 'x' or 'y'. Please check your input data.")
  }

  # Extract the minimum and maximum x values for text placement
  min_x <- min(data$x, na.rm = TRUE)
  max_x <- max(data$x, na.rm = TRUE)
  
  quad_data_l2 <- filter(quad, lm == key[[1]], English == "L2")
  quad_data_l1 <- filter(quad, lm == key[[1]], English == "L1")
  if (NORM_TIMES == TRUE) {
    ylabel <- "Slowdown"
  } else {
    ylabel <- "Slowdown (ms)"
  }
  # ylabel <- ifelse(NORM_TIMES == TRUE, "Slowdown", "Slowdown (ms)")

  p <- ggplot(data) +
    theme_bw(base_size = 30) +

    # Smooth the lines using geom_smooth()
    # geom_smooth(aes(x = x, y = y, col = English), method = "gam", formula = y ~ s(x, bs = "cs"), se = FALSE, size = 1) +

    # Smooth the confidence intervals using geom_smooth()
    # geom_ribbon(aes(x = x, ymin = y_lower, ymax = y_upper, fill = English), alpha = 0.2) +

    # Smooth the lines and ribbons using geom_smooth()
    geom_smooth(aes(x = x, y = y, col = English, fill = English),
      method = "gam", formula = y ~ s(x, bs = "cs"),
      se = FALSE, size = 1, alpha = 0.2
    ) +
    # geom_ribbon(aes(x = x, ymin = y_lower, ymax = y_upper, fill = English), alpha = 0.2) +

    # Add significance stars for L1 and L2
    geom_text(
      data = quad_data_l1, aes(x = min_x, y = Inf, label = quad_sig_stars),
      vjust = 1.1, hjust = -0.1, size = 12, color = colors["L1"]
    ) +
    geom_text(
      data = quad_data_l2, aes(x = max_x, y = Inf, label = quad_sig_stars),
      vjust = 1.1, hjust = 1.1, size = 12, color = colors["L2"]
    ) +

    # Use facet_wrap to create separate panels
    facet_wrap(fix_measure ~ word_property, dir = "h", scales = "free") +

    # Customize colors and other aesthetics
    scale_color_manual(values = colors) +
    scale_fill_manual(values = colors) +

    # Ensure x and y axis limits are correctly set:
    # scale_x_continuous(expand = expansion(mult = c(0, 0.05))) +
    # scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
    # set limit for x axis by word_property:

    scale_x_continuous(expand = expansion(mult = c(0, 0.05)), limits = c(0,25)) +

    scale_alpha_manual(values = c(0.3, 0.1)) +
    
    theme(plot.title = element_text(size = 30, hjust = 0.5)) +
    ylab(ylabel) + xlab(NULL)

  return(p)
}

plot_gam_percentile <- function(data, key, quad) {
  # Ensure English is a factor
  # data$English <- as.factor(data$English)

  # Remove any rows with NA or non-finite values in key columns
  data <- data %>% filter(is.finite(x), is.finite(y), is.finite(y_lower), is.finite(y_upper))

  # Check if data$x has valid values after filtering
  if (nrow(data) == 0) {
    stop("No valid data in 'x' or 'y'. Please check your input data.")
  }

  # Extract the minimum and maximum x values for text placement
  min_x <- min(data$x, na.rm = TRUE)
  max_x <- max(data$x, na.rm = TRUE)
  
  # Calculate the 95th percentile of x values for the SURPRISAL word property
  x_limit <- data %>% 
    filter(word_property == "SURPRISAL") %>% 
    summarize(x_95 = quantile(x, 0.95, na.rm = TRUE)) %>% 
    pull(x_95)
  
  # Use the calculated 95th percentile as the upper limit for x axis
  if (is.na(x_limit)) {
    x_limit <- 25  # Default upper limit if SURPRISAL data is not found
  }
  
  quad_data_l2 <- filter(quad, lm == key[[1]], English == "L2")
  quad_data_l1 <- filter(quad, lm == key[[1]], English == "L1")
  if (NORM_TIMES == TRUE) {
    ylabel <- "Slowdown"
  } else {
    ylabel <- "Slowdown (ms)"
  }
  # ylabel <- ifelse(NORM_TIMES == TRUE, "Slowdown", "Slowdown (ms)")

  p <- ggplot(data) +
    theme_bw(base_size = 30) +

    # Smooth the lines using geom_smooth()
    geom_smooth(aes(x = x, y = y, col = English, fill = English),
      method = "gam", formula = y ~ s(x, bs = "cs"),
      se = FALSE, size = 1, alpha = 0.2
    ) +

    # Add significance stars for L1 and L2
    geom_text(
      data = quad_data_l1, aes(x = min_x, y = Inf, label = quad_sig_stars),
      vjust = 1.1, hjust = -0.1, size = 12, color = colors["L1"]
    ) +
    geom_text(
      data = quad_data_l2, aes(x = max_x, y = Inf, label = quad_sig_stars),
      vjust = 1.1, hjust = 1.1, size = 12, color = colors["L2"]
    ) +

    # Use facet_wrap to create separate panels
    facet_wrap(fix_measure ~ word_property, dir = "h", scales = "free") +

    # Customize colors and other aesthetics
    scale_color_manual(values = colors) +
    scale_fill_manual(values = colors) +

    # Set limit for x axis by word_property
    scale_x_continuous(expand = expansion(mult = c(0, 0.05)), limits = c(0, x_limit)) +

    scale_alpha_manual(values = c(0.3, 0.1)) +
    
    theme(plot.title = element_text(size = 30, hjust = 0.5)) +
    ylab(ylabel) + xlab(NULL)

  return(p)
}

if (BY_L1 == TRUE){
  plots <- results_long %>% group_by(lm) %>% group_map(plot_gam_by_l1, quad)    
} else { # Choose the plot function to use plot gam plot the full fit or plot_gam_smooth for the smooth fit
  # plots <- results_long %>% group_by(lm) %>% group_map(plot_gam, quad)
  # Plot only to the chosen percentile
  # plots <- results_long %>% group_by(lm) %>% group_map(plot_gam_percentile, quad)
  # Plot smooth fit
  plots <- results_long %>% group_by(lm) %>% group_map(plot_gam_smooth, quad)
}

p1 <- plot_grid(plots[[1]], density_plots[[1]], ncol = 1, align = "v", axis = "lr", rel_heights = c(3, 0.5))
p1

if (BY_L1 == TRUE){
ggsave(file=paste("figures/","SURP_pythia-70m_cleaned_scaled", "-",as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),"_byL1",".pdf", sep=""), height=24,width=28, p1)
} else {
  ggsave(file=paste("figures/","SURP_pythia-70m_cleaned_scled", "-",as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),".pdf", sep=""), height=24,width=28, p1)
}


### Analysis 3: Effect Size (Mean slowdown) as a function of English proficiency
# <!-- ```{r, fig.width=12,fig.height=10} -->
print("Analysis 3: Effect Size (Mean slowdown) as a function of English proficiency")
plot_slowdowns <- function(l2_slowdowns, l1_means, fig_title, coef_sig){
      x_label = "MPT English Proficiency"  
      if (startsWith(ENGLISH_TEST, "Comprehension")){
        x_label = "Comprehension"
      }
      p <- ggplot() +
              theme_bw(base_size = 30) +
              facet_wrap(fix_measure ~ word_property, scales = "free_y")  +  
              geom_point(data = l2_slowdowns, aes(x=MPT, y=slowdown_current, color = "L2"), size = 4,  alpha = 0.2) + #col = English
              geom_smooth(data = l2_slowdowns, aes(x=MPT, y=slowdown_current),  #col = English
                          formula = y~s(x), method = "gam", fill = "blue",   alpha = 0.2) + #fill = L1,
              geom_hline(aes(yintercept = mean_current, color = "L1"), l1_means) +
              geom_rect(data = l1_means, aes(xmin = -Inf, xmax = Inf, ymin = upper_current, ymax = lower_current),  
                        fill = "red", alpha = 0.2) + 
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p1", p1_stars)), vjust=1.1, hjust=-0.05, size = 10) +  
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p2", p2_stars)), vjust=2.6, hjust=-0.05, size = 10) +  
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p3", p3_stars)), vjust=4.1, hjust=-0.05, size = 10) +  
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p4", p4_stars)), vjust=5.6, hjust=-0.05, size = 10) + 
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p5", p5_stars)), vjust=7.1, hjust=-0.05, size = 10) + 
              theme(plot.title = element_text(size = 30, hjust = 0.5)) + 
              labs(x = paste(x_label, "Score", sep=" "),
                   y = "Mean Slowdown",
                   color = "English") +
              guides(fill=FALSE) +
              scale_color_manual(values = colors)
      return(p)
}

p2stars <- function(p){
  stars = symnum(p, corr = FALSE, na = FALSE, cutpoints = c(0, 0.001, 0.01, 0.05, 1), symbols = c("***", "**", "*", "(.)"))
  return(stars)
}

coef_sig <- function(df){
    #Assign L1 speakers maximum MPT scores
    if (ENGLISH_TEST == "MichiganLG"){
      df <- df %>% mutate(MPT = replace(MPT, L1 == "English", 50)) 
    }
  
    mid_point <- (max(df$MPT )+min(df$MPT )) / 2
    df2 = filter(df, MPT > mid_point)
    #m1 full GAM
    m1 = gam(slowdown_current ~ s(MPT), data = df)
    p1 = data.frame(summary(m1)$s.table)$p.value
    p1_stars <- p2stars(p1) 
    #m2 quadratic
    m2 = lm(slowdown_current ~ MPT+ I(MPT^2), data = df)
    p2 = coef(summary(m2))["I(MPT^2)","Pr(>|t|)"]
    p2_stars <- p2stars(p2)
    #m3 linear past proficiency midpoint + L2 offset
    m3 = lm(slowdown_current ~ English + MPT, data = df2)
    p3 = coef(summary(m3))["EnglishL1", "Pr(>|t|)"]
    p3_stars <- p2stars(p3)
    #m4 quadratic + l2 offset
    m4 = lm(slowdown_current ~ English + MPT + I(MPT^2), data = df)
    p4 = coef(summary(m4))["EnglishL1","Pr(>|t|)"]
    p4_stars <- p2stars(p4)
    #m5 linear past proficiency midpoint
    m5 = lm(slowdown_current ~ MPT, data = df2)
    p5 = coef(summary(m5))["MPT", "Pr(>|t|)"]
    p5_stars <- p2stars(p5)
    return(data.frame(p1, p1_stars, p2, p2_stars, p3, p3_stars, p4, p4_stars, p5, p5_stars))
}

### Reached Here! ###

subj_slowdowns <- report_ia %>% group_by(lm, fix_measure, SUBJECT) %>% do(fit_gam_subj(.)) %>% 
                                    mutate(MPT = map_dbl(SUBJECT, function(x){metadata[toString(x), ENGLISH_TEST]}),
                                           L1 = as.factor(unlist(map(SUBJECT, function(x){metadata[toString(x),"L1"]}))),
                                           English = as.factor(ifelse(L1 == "English", "L1", "L2"))) %>% ungroup
l1_slowdowns <- filter(subj_slowdowns, L1 == 'English')
l2_slowdowns <- filter(subj_slowdowns, L1 != 'English')
l1_means <- l1_slowdowns %>% group_by(lm, fix_measure,word_property) %>% summarize(mean_current = mean(slowdown_current),
                                                                    upper_current = upper(slowdown_current),
                                                                    lower_current = lower(slowdown_current))%>% ungroup 
                                                          
coefs_sig <- subj_slowdowns %>% group_by(lm, fix_measure, word_property) %>% do(coef_sig(.))

plots <- plot_slowdowns(l2_slowdowns, l1_means, LM_DEFAULT, coefs_sig)
ggsave(file=paste("figures/by-MPT-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),".pdf", sep = ""), height = 20, width = 25)
cat("DATA PORTION", DATA_SUBSET, "\n")
print(plots)


### Analysis 2: Effect magnitude in L1 and L2
# <!-- ```{r,fig.width=10,fig.height=8} -->
print("Analysis 2: Effect magnitude in L1 and L2")
plot_means <- function(means, tests_l1_l2, fig_title){
      ylabel = ifelse(NORM_TIMES == TRUE, "Mean Slowdown", "Mean Slowdown (ms)")
      p <- ggplot() +
              theme_bw(base_size = 30) + #
              facet_grid(fix_measure ~ word_property, scales = "free_y")  +  
              geom_bar(stat = "identity", data = means, aes(x=English, y=mean_current, fill=English), size = 4,  alpha = 0.5) +
              geom_errorbar(data = means, aes(x=English, ymin=lower_current, ymax=upper_current), width=0.3, size = 1) +
              geom_text(data = tests_l1_l2, aes(x = -Inf, y = Inf, vjust=1.1, hjust=-0.05, label = stars), size = 12)  +
              theme(plot.title = element_text(size = 50, hjust = 0.5)) + 
              scale_fill_manual(values = colors)+
              labs(x = "English",
                   y = ylabel)
      return(p)
}
means <- subj_slowdowns %>% group_by(lm, fix_measure, word_property, English) %>% summarize(mean_current = mean(slowdown_current),
                                                                             upper_current = upper(slowdown_current),
                                                                             lower_current = lower(slowdown_current))%>% ungroup 
tests_l1_l2 <- subj_slowdowns %>% group_by(lm, fix_measure, word_property) %>% 
                             summarise(p = t.test(slowdown_current[English=="L1"], slowdown_current[English=="L2"])$p.value) %>%
                             mutate(stars = p2stars(p))
tests_freq_surp <- subj_slowdowns %>% group_by(lm, fix_measure, English) %>% 
                             summarise(p = t.test(slowdown_current[word_property=="FREQUENCY"], slowdown_current[word_property=="SURPRISAL"])$p.value) %>%
                             mutate(stars = p2stars(p))

p_means <- plot_means(means, tests_l1_l2, "Slowdowns")
ggsave(file=paste("figures/mean_slowdown_pythia-70m-v2-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),".pdf", sep = ""), height = 20, width = 25)
# dir.create("figures/tests_l1_l2_pythia-70m-EleutherAI", recursive = TRUE, showWarnings = FALSE)
write.table(tests_l1_l2, file=paste("figures/tests_l1_l2_pythia-70m-v2-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),".txt", sep = ""), 
            sep = "\t", append = FALSE, dec = ".", row.names = TRUE, col.names = TRUE)
# dir.create("figures/tests_freq_surp_pythia-70m-EleutherAI", recursive = TRUE, showWarnings = FALSE)
write.table(tests_freq_surp, file=paste("figures/tests_freq_surp_pythia-70m-v2", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),".txt", sep = ""), 
            sep = "\t", append = FALSE, dec = ".", row.names = TRUE, col.names = TRUE)

p_means
tests_l1_l2
tests_freq_surp

### Analysis 4: Difference between frequency and suprisal effects
# <!-- ```{r, fig.width=10,fig.height=3} -->
print("Analysis 4: Difference between frequency and suprisal effects")
plot_slowdowns_ratio <- function(l2_slowdowns, l1_means, fig_title, coef_sig){
      x_label = "MPT English Proficiency"  
      if (startsWith(ENGLISH_TEST, "Comprehension")){
        x_label = "Comprehension"
      }
      p <- ggplot() +
              theme_bw(base_size = 30) +
              facet_wrap(~ fix_measure, scales = "free")  +  
              geom_point(data = l2_slowdowns, aes(x=MPT, y=slowdown_current, color = "L2"), size = 4,  alpha = 0.2) + #col = English
              geom_smooth(data = l2_slowdowns, aes(x=MPT, y=slowdown_current),  #col = English
                          formula = y~s(x), method = "gam", fill = "blue",   alpha = 0.2) + #fill = L1,
              geom_hline(aes(yintercept = mean_current, color = "L1"), l1_means) +
              geom_rect(data = l1_means, aes(xmin = -Inf, xmax = Inf, ymin = upper_current, ymax = lower_current),  
                        fill = "red", alpha = 0.2) + 
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p1", p1_stars)), vjust=1.1, hjust=-0.05, size = 10) +  
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p2", p2_stars)), vjust=2.6, hjust=-0.05, size = 10) +  
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p3", p3_stars)), vjust=4.1, hjust=-0.05, size = 10) +  
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p4", p4_stars)), vjust=5.6, hjust=-0.05, size = 10) + 
              geom_text(data = coef_sig, aes(x = -Inf, y= Inf, label= paste("p5", p5_stars)), vjust=7.1, hjust=-0.05, size = 10) + 
              theme(plot.title = element_text(size = 30, hjust = 0.5)) + 
              labs(x = paste(x_label, "Score", sep=" "),
                   y = "Freq Slowdown - Surp Slowdown",
                   color = "English") +
              guides(fill=FALSE) +
              scale_color_manual(values = colors)
        
      return(p)
}

surp<- filter(subj_slowdowns, word_property == "SURPRISAL") 
freq<- filter(subj_slowdowns, word_property == "FREQUENCY") 
slowdowns_diff <- freq %>% mutate(slowdown_current = slowdown_current-surp$slowdown_current,
                             slowdown_previous = slowdown_previous-surp$slowdown_previous,
                             slowdown_total = slowdown_total-surp$slowdown_total)
slowdowns_diff_l1 <- filter(slowdowns_diff, L1 == 'English')
slowdowns_diff_l2 <- filter(slowdowns_diff, L1 != 'English')
slowdowns_diff_l1
diff_l1_means <- slowdowns_diff_l1 %>% group_by(lm, fix_measure,word_property) %>% summarize(mean_current = mean(slowdown_current),
                                                                    upper_current = upper(slowdown_current),
                                                                    lower_current = lower(slowdown_current))%>% ungroup 

#test_df <- slowdowns_diff %>% mutate(MPT = replace(MPT, L1 == "English", 50)) 
coefs_sig <- slowdowns_diff %>% group_by(lm, fix_measure) %>% do(coef_sig(.))

plots <- plot_slowdowns_ratio(slowdowns_diff_l2, diff_l1_means, LM_DEFAULT, coefs_sig)
ggsave(file=paste("figures/FREQ-SURP-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),".pdf", sep = ""), height = 8, width = 28)
cat("DATA PORTION", DATA_SUBSET, "\n")
print(plots)


### SI: Analysis 2 by L1
# <!-- ```{r,fig.width=10,fig.height=8} -->
print("SI: Analysis 2 by L1")
plot_means2 <- function(means, tests_l1_l2, fig_title){
      langs_custom_order <- c("English", "Arabic", "Chinese", "Japanese", "Portuguese", "Spanish")
      ylabel = ifelse(NORM_TIMES == TRUE, "Mean Slowdown", "Mean Slowdown (ms)")
      p <- ggplot() +
              theme_bw(base_size = 30) + #
              facet_grid(fix_measure ~ word_property, scales = "free_y")  +  
              geom_bar(stat = "identity", data = means, aes(x=L1, y=mean_current, fill=L1), size = 4,  alpha = 0.5) +
              geom_errorbar(data = means, aes(x=L1, ymin=lower_current, ymax=upper_current), width=0.3, size = 1) +
              geom_text(data = tests_l1_l2, aes(x = -Inf, y = Inf, vjust=1.1, hjust=-0.05, label = stars_arabic), size = 10, color = l1_colors["Arabic"])  +
              geom_text(data = tests_l1_l2, aes(x = -Inf, y = Inf, vjust=2.6, hjust=-0.05, label = stars_chinese), size = 10, color = l1_colors["Chinese"])  +
              geom_text(data = tests_l1_l2, aes(x = -Inf, y = Inf, vjust=4.1, hjust=-0.05, label = stars_japanese), size = 10, color = l1_colors["Japanese"])  +
              geom_text(data = tests_l1_l2, aes(x = -Inf, y = Inf, vjust=5.6, hjust=-0.05, label = stars_portuguese), size = 10, color = l1_colors["Portuguese"])  +
              geom_text(data = tests_l1_l2, aes(x = -Inf, y = Inf, vjust=7.1, hjust=-0.05, label = stars_spanish), size = 10, color = l1_colors["Spanish"])  +
              theme(plot.title = element_text(size = 50, hjust = 0.5),
                    axis.text.x=element_text(angle = 45, hjust = 1)) + 
              scale_fill_manual(values = l1_colors)+
              labs(x = "L1",
                   y = ylabel)+
              scale_x_discrete(limits = langs_custom_order)
      return(p)
}
means <- subj_slowdowns %>% group_by(lm, fix_measure, word_property, L1) %>% summarize(mean_current = mean(slowdown_current),
                                                                             upper_current = upper(slowdown_current),
                                                                             lower_current = lower(slowdown_current))%>% ungroup 
tests_l1_l2 <- subj_slowdowns %>% group_by(lm, fix_measure, word_property) %>% 
                             summarise(p_arabic = t.test(slowdown_current[L1=="English"], slowdown_current[L1=="Arabic"])$p.value,
                                       p_chinese = t.test(slowdown_current[L1=="English"], slowdown_current[L1=="Chinese"])$p.value,
                                       p_japanese = t.test(slowdown_current[L1=="English"], slowdown_current[L1=="Japanese"])$p.value,
                                       p_portuguese = t.test(slowdown_current[L1=="English"], slowdown_current[L1=="Portuguese"])$p.value,
                                       p_spanish = t.test(slowdown_current[L1=="English"], slowdown_current[L1=="Spanish"])$p.value) %>%
                             mutate(stars_arabic = p2stars(p_arabic),
                                    stars_chinese = p2stars(p_chinese),
                                    stars_japanese = p2stars(p_japanese),
                                    stars_portuguese = p2stars(p_portuguese),
                                    stars_spanish = p2stars(p_spanish))

tests_freq_surp <- subj_slowdowns %>% group_by(lm, fix_measure, L1) %>% 
                             summarise(p = t.test(slowdown_current[word_property=="FREQUENCY"], slowdown_current[word_property=="SURPRISAL"])$p.value) %>%
                             mutate(stars = p2stars(p))
p_means <- plot_means2(means, tests_l1_l2, "Slowdowns")
ggsave(file=paste("figures/mean_slowdown-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),"_byL1.pdf", sep = ""), height = 20, width = 25)
write.table(tests_l1_l2, file=paste("figures/tests_l1_l2-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),"_byL1.txt", sep = ""), 
            sep = "\t", append = FALSE, dec = ".", row.names = TRUE, col.names = TRUE)
write.table(tests_freq_surp, file=paste("figures/tests_freq_surp-", LM_DEFAULT, "-", as.symbol(NORM_TIMES),"_", as.symbol(DATA_SUBSET),"_byL1.txt", sep = ""), 
            sep = "\t", append = FALSE, dec = ".", row.names = TRUE, col.names = TRUE)
p_means
tests_freq_surp
tests_l1_l2

### Reached here quickly as well ###

### SI plots
print("SI: Plots")
# Load Fixation report
path = paste0(CELER_PATH, "data_v2.0/sent_fix.tsv")
report_fix <- read.table(path, header = TRUE, quote = "", sep = "\t", stringsAsFactors = FALSE) 

#individual regime
report_fix <- report_fix %>% filter(shared_text == 0)
report_fix <- report_fix %>%
                  rename(SUBJECT = list,
                         TRIAL = trial) %>%
                  # filter out saccades to locations that are outside the text area
                  filter(CURRENT_FIX_INTEREST_AREA_ID != '.') %>% 
                  # set default frequency and suprisal
                  mutate(SUBJECT = as.factor(SUBJECT),
                         WORD_ID = as.factor(paste(TRIAL, CURRENT_FIX_INTEREST_AREA_ID, sep = "_")),
                         WORD_NORM = as.factor(WORD_NORM)) %>%
                  # add L1 and proficiency information form metadata
                  mutate(MPT = map_dbl(SUBJECT, function(x){metadata[toString(x), ENGLISH_TEST]}),
                         L1 = unlist(map(SUBJECT, function(x){metadata[toString(x),"L1"]})),
                         English = as.factor(ifelse(L1 == "English", "L1", "L2")))
report_fix <- report_fix %>% filter(!grepl("NUM", WORD_NORM), #numbers
                                  !grepl('^[[:punct:]]|[[:punct:]]$', CURRENT_FIX_INTEREST_AREA_LABEL)) #punctuation


### SI: Other
# <!-- ```{r,fig.width=12,fig.height=9} -->
print("SI: Other")
mean_lmer <- function(report){
  se = as_tibble(coef(summary(lmer(CURRENT_FIX_DURATION ~ 1 + (1 |SUBJECT),
                                     control=lmerControl(optimizer = "bobyqa", calc.derivs = FALSE), data = report))))
  se <- se %>% mutate(CI = `Std. Error`*1.96)
  return(se)    
}
l1_means <- report_fix %>% group_by(L1) %>% do(mean_lmer(.))

p<- ggplot(l1_means, aes(x=L1, y=Estimate, fill = L1)) + 
      theme_bw(base_size = 20) +
      geom_bar(stat="identity") +
      geom_errorbar(aes(ymin=Estimate-CI, ymax=Estimate+CI), width=.2,
                     position=position_dodge(.9)) +
      scale_fill_manual(values = colors) +
      ylab("Mean Fixation Duration") +
      scale_x_discrete(limits=c("English", "Arabic", "Chinese", "Japanese", "Portuguese", "Spanish"))+
      theme(legend.position="none")
ggsave(file="figures/fixation_duration_by_L1.pdf", height=9,width=12, p)
p



subj_fix <- report_fix %>% group_by(SUBJECT) %>% summarize(Estimate = mean(CURRENT_FIX_DURATION),
                                               CI = 1.96*sem(CURRENT_FIX_DURATION),
                                               MPT = unique(MPT),
                                              L1 = unique(L1))
subj_fix_l1 = subj_fix %>% filter(L1 == "English")
L1_mean = mean(subj_fix_l1$Estimate)
CI =1.96*sem(subj_fix_l1$Estimate)
p <- ggplot() +
        theme_bw(base_size = 20) +
  geom_point(data = filter(subj_fix, L1 != "English"), aes(x=MPT, y=Estimate), size = 8, color = 'blue', alpha = 0.4) +
  geom_smooth(data = filter(subj_fix, L1 != "English"), aes(x=MPT, y=Estimate), method = "gam", fill = "blue", alpha = 0.2) +
  geom_hline(aes(yintercept = L1_mean), color = "red") +
             geom_rect(aes(xmin = -Inf, xmax = Inf, ymin = L1_mean- CI, ymax = L1_mean + CI),  
                       fill = "red", alpha = 0.2) +
    ylab("Mean Fixation Duration") + xlab('MPT English Proficiency Score')+
      scale_fill_manual(values = colors) 

ggsave(file="figures/fixation_duration_by_MPT.pdf", height=9,width=12, p)
p



# Appendix - correctly answered comprehension questions

l1_metadata = filter(metadata, L1 == "English")
L1_mean = mean(l1_metadata$Comprehension)
CI =1.96*sem(l1_metadata$Comprehension)

l2_metadata = filter(metadata, L1 != "English")
m = lm(Comprehension ~ MichiganLG, data = l2_metadata)
r2_label = sprintf("italic(R)^2 ~ '=' ~ %.2g", summary(m)$r.squared)

p<- ggplot() +
        theme_bw(base_size = 20) +
  geom_point(data = l2_metadata, aes(x=MichiganLG, y=Comprehension), size = 8, color = "blue", alpha = 0.4) +
  ylab('% Correcty Answered Comprehension Questions') + xlab('MPT English Proficiency Score') +
   geom_hline(aes(yintercept = L1_mean), color = "red") +
             geom_rect(aes(xmin = -Inf, xmax = Inf, ymin = L1_mean- CI, ymax = L1_mean + CI),  
                       fill = "red", alpha = 0.2) +
  annotate("text", x = -Inf, y = Inf, label = r2_label, parse = TRUE, vjust=1.5, hjust=-0.5, size = 7)
p
ggsave(file = "figures/comprehension.pdf", height = 9, width = 12, p)

## reached here :) ##