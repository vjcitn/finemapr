
#' Run FINEMAP.
#'
#' @examples
#' if (interactive()) {
#' ex <- example_finemap()
#' out <- finemapr(list(ex$tab1, ex$tab2), list(ex$ld1, ex$ld2), list(ex$n1, ex$n2), args = "--n-causal-max 1")
#' out <- finemapr(list(ex$tab1, ex$tab2), list(ex$ld1, ex$ld2), list(ex$n1, ex$n2), method = "paintor", args = "-enumerate 1")
#'
#' }
#' @export
finemapr <- function(tab, ld, n, 
  annot, annotations, 
  prop_credible = 0.95,
  method = c("finemap", "paintor"),
  dir_run,
  tool, args = "",
  # finemap par
  prior_k,
  # other par
  save_ld = FALSE,
  ret = c("results", "zscore", "ld"))
{
  ### arg
  method <- match.arg(method)
  ret <- match.arg(ret)
  
  missing_tab <- missing(tab)
  missing_ld <- missing(ld)
  missing_n <- missing(n)

  missing_prior_k <- missing(prior_k)
  
  if(missing(tool)) {
    tool <-switch(method,
      "finemap" = getOption("finemapr_finemap"),
      "paintor" = getOption("finemapr_paintor"),
      stop("error in switch"))
  }
  
  ### create an object of class `Finemapr`: basic slots and class attribute
  out <- list(method = method, tool = tool,
    dir_run = paste("run", method, sep = "_"), args = args,
    # finemap slots
    prior_k = switch(missing_prior_k + 1, prior_k, NULL),
    # other slots
    num_loci = ifelse(class(tab)[1] == "list", length(tab), 1),
    prop_credible = prop_credible)

  class_finemapr <- switch(out$method,
    "finemap" = "FinemaprFinemap",
    "paintor" = "FinemaprPaintor",
    stop("switch error on `method`"))
  oldClass(out) <- c(class_finemapr, "Finemapr", oldClass(out))

  ### process input
  stopifnot(!missing_tab)
  out <- process_tab(out, tab)
  if(ret == "zscore") return(out)
  
  stopifnot(!missing_ld)
  out <- process_ld(out, ld)
  if(ret == "ld") return(out)
    
  stopifnot(!missing_n)
  out <- process_n(out, n)
  
  if(method == "paintor") { 
    out <- process_annot(out, annot, annotations)
  }

  ### write files 
  write_files(out)
  
  #### run
  out <- run_tool(out)

  #### read results
  out <- collect_results(out)
  
  ### return
  if(!save_ld) {
    out$ld <- NULL
  }
  
  return(out)
}

#' @rdname Finemapr_cl
#' @export
process_tab.Finemapr <- function(x, tabs, ...)
{
  ### process input
  if(class(tabs)[1] != "list") {
    tabs <- list(tabs)
  }
  
  stopifnot(length(tabs) == x$num_loci)
  
  ### prepare tabels of Z-scores
  out_tabs <- lapply(tabs, function(tab) {
    tab <- as_data_frame(tab)

    stopifnot(ncol(tab) >= 2)
    
    names_all <- names(tab)
    names_select <- c(
      finemapr_find_name("snp", names_all, strict = TRUE),
      finemapr_find_name("zscore", names_all, strict = TRUE))
    names_new <- finemapr_names_tab()
    
    name_pos <- finemapr_find_name("pos", names_all, strict = FALSE)
    if(!is.null(name_pos)) {
      names_select <- c(names_select, name_pos)
      names_new <- c(names_new, finemapr_names_tab_pos())
    }
    
    tab <- select_(tab, .dots = names_select)
    names(tab) <- names_new
    
    # manage missing Z-scores
    snps_zscore_missing <- filter(tab, is.na(zscore)) %$% snp 
    tab <- filter(tab, !is.na(zscore)) 
  
    # arrange & add `rank_pp` column
    tab <- arrange(tab, -abs(zscore)) %>%
      mutate(rank_z = seq(1, n())) %>%
      select(rank_z, everything())
  
    list(tab = tab, 
      snps_zscore_missing = snps_zscore_missing)
  })
  
  ### write back to `x` and return
  x$tab <- lapply(out_tabs, function(x) x$tab)
  x$snps_zscore <- lapply(out_tabs, function(x) x$tab[[finemapr_names_tab_snp()]])
    
  x$snps_zscore_missing <- lapply(out_tabs, function(x) x$snps_zscore_missing)
  
  return(x)
}

#' @rdname Finemapr_cl
#' @export
process_ld.Finemapr <- function(x, lds, ...)
{
  ### process input
  if(class(lds)[1] != "list") {
    lds <- list(lds)
  }
  
  stopifnot(length(lds) == x$num_loci)
  
  ### prepare tabels of Z-scores
  out_lds <- lapply(seq_along(lds), function(locus) {
    ld <- lds[[locus]]
    
    stopifnot(class(ld) == "matrix")
    stopifnot(!is.null(colnames(ld)))
    stopifnot(!is.null(rownames(ld)))
    
    # manage SNP names across variables: ld, zscore    
    snps_ld <- colnames(ld)
    snps_zscore <- x$snps_zscore[[locus]]
    
    ind <- snps_ld %in% snps_zscore
    snps_finemap <- snps_ld[ind]
    snps_missing_finemap <- snps_zscore[!(snps_zscore %in% snps_finemap)]
    snps_missing_ld <- snps_ld[!ind]
    
    # check the proportion of `snps_missing_ld`
    prop_snps_missing <- length(snps_missing_ld) / 
      (length(snps_missing_ld) + length(snps_finemap))
    #stopifnot(prop_snps_missing < 0.20)
    
    # subset LD matrix
    ld <- ld[snps_finemap, snps_finemap]
    
    # some tools require all diagonals to be `1`
    stopifnot(all(round(diag(ld), 4) == 1))
    diag(ld) <- 1
   
    list(ld = ld, 
      snps_missing_ld = snps_missing_ld,
      snps_finemap = snps_finemap,
      snps_missing_finemap = snps_missing_finemap)
  })
  
  x$ld <- lapply(out_lds, function(x) x$ld)
  x$snps_missing_ld <- lapply(out_lds, function(x) x$snps_missing_ld)  
  x$snps_finemap <- lapply(out_lds, function(x) x$snps_finemap)
  x$snps_missing_finemap <- lapply(out_lds, function(x) x$snps_missing_finemap)
    
  for(i in seq(1, x$num_loci)) {
    x$tab[[i]] <- mutate(x$tab[[i]], finemap = snp %in% x$snps_finemap[[1]])
  }
  
  return(x)
}

process_n.Finemapr <- function(x, ns, ...)
{
  ### process input
  if(class(ns)[1] != "list") {
    ns <- list(ns)
  }
  
  if(length(ns) == 1) {
    n <- ns[[1]]
    stopifnot(length(n) == 1)
    ns <- rep(n, x$num_loci) %>% as.list
  }
  stopifnot(length(ns) == x$num_loci)  

  x$n <- ns
  
  return(x)
}
