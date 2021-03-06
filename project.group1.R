options(stringsAsFactors = FALSE, useFancyQuotes = FALSE)
library(gt23)  # https://github.com/everettJK/package.geneTherapy.gt23
library(RMySQL)
library(parallel)
library(gtools)
library(GenomicRanges)
library(grDevices)
library(RColorBrewer)
library(gintools)
library(tidyverse)
source('./supp.R')

savePointPrefix         <- 'group1'
reportSubjectsFile      <- 'data/group1.subjects'
reportCellTransfersFile <- 'data/group1.cellTransfers.tsv'

reportSubjects <- scan(reportSubjectsFile, what = 'character', sep = '\n')

# cellTransfers   <- read.table('data/cellTransfers.tsv', header=TRUE, sep='\t', check.names = FALSE)
cellTransfers <- data.frame(From = 'none', To = 'none')
if(file.exists(reportCellTransfersFile)) cellTransfers <- read.table(reportCellTransfersFile, header=TRUE, sep='\t', check.names = FALSE)


# Read in sample data & subset to the subjects in this report group.
invisible(sapply(dbListConnections(MySQL()), dbDisconnect))
dbConn  <- dbConnect(MySQL(), group='specimen_management')
samples <- dbGetQuery(dbConn, 'select * from gtsp where Trial="CYS"')
samples <- subset(samples, toupper(samples$Patient) %in% toupper(reportSubjects))


# Create a list of all GTSPs that passed through the INSPIIRED pipeline.
dbConn  <- dbConnect(MySQL(), group='intsites_miseq')
intSitesamples <- unname(unlist(dbGetQuery(dbConn, 'select sampleName from samples where sampleName like "%GTSP%"')))
intSitesamples <- unique(gsub('\\-\\d+$', '', intSitesamples))


# Retrieve and process intSites.
# Added a fragment width filter to preven standardization tools from breaking.
if(! file.exists(paste0('savePoints/', savePointPrefix, '.1.RData'))){
  intSites <- getDBgenomicFragments(samples$SpecimenAccNum, 'specimen_management', 'intsites_miseq') 
  intSites <- intSites[end(intSites) - start(intSites) + 1 >= 5] %>%  
                stdIntSiteFragments() %>%
                collapseReplicatesCalcAbunds() %>%
                annotateIntSites()
  
  save.image(file = paste0('savePoints/', savePointPrefix, '.1.RData'))
} else { 
  load( paste0('savePoints/', savePointPrefix, '.1.RData'))
}


#--------------------------------------------------------------------------------------------------

# Hot fixes
samples$Timepoint  <- toupper(samples$Timepoint)
intSites$timePoint <- toupper(intSites$timePoint)
intSites <- subset(intSites, ! GTSP %in% c('GTSP1708', 'GTSP1709'))



# Add VCN values.
intSites$VCN <- sapply(intSites$GTSP, function(x){ round(samples[match(x, samples$SpecimenAccNum),]$VCN, digits=3) })
intSites[which(intSites$VCN == 0)]$VCN <- NA


# Add organism nick name
intSites$organism <- ifelse(intSites$refGenome == 'hg38', 'human', 'mouse')


# First, check with CYS samples are in the full list of INSPIIRED samples and then determine which 
# of those samples are not in the intSite object which requires at least 1 site to be found for inclussion. 
processedSamples <- samples$SpecimenAccNum[samples$SpecimenAccNum %in% intSitesamples]
samplesNoIntSitesFound <- processedSamples[!processedSamples %in% intSites$GTSP]

failedSampleTable <-
  samples %>%
  select(SpecimenAccNum, CellType, Patient, Timepoint, SpecimenInfo) %>%
  filter(SpecimenAccNum %in% samplesNoIntSitesFound) %>%
  mutate(SpecimenInfo = ifelse(SpecimenInfo == 'Mouse', 'none', SpecimenInfo))



# Create an organism specific effort table.
summaryTable <- 
  data.frame(intSites) %>%
  mutate(patientPosid = paste(patient, posid)) %>%
  group_by(organism) %>%
  summarise(samples = n_distinct(GTSP),
            nReads  = ppNum(sum(reads)),
            nFrags  = ppNum(sum(estAbund)),
            nSites  = ppNum(n_distinct(patientPosid))) %>%
  ungroup()



# Create a table of human subjects with the percent of sites near suspect oncogenes.
humanSitesNearOnco <- 
  data.frame(subset(intSites, organism=='human')) %>%
  group_by(patient) %>%
  summarise(percentNearOnco = n_distinct(posid[abs(nearestOncoFeatureDist) <= 50000]) / n_distinct(posid)) %>%
  ungroup() %>%
  arrange(percentNearOnco) %>%
  mutate(source = 'CYS') %>%
  data.frame()


# Read in previously published WAS trial d0 data and rename the subjects and then determin the percentage
# of intSites near oncogenes.

n <- 1
WASintSites_d0 <- readRDS('data/WAS_d0_intSites.rds')
WASintSites_d0 <- unlist(GRangesList(lapply(split(WASintSites_d0, WASintSites_d0$patient), 
                                            function(x){ x$patient <- paste('WAS subject', n); n <<- n+1; x})))


wasSitesNearOnco <- 
  data.frame(WASintSites_d0) %>%
  group_by(patient) %>%
  summarise(percentNearOnco = n_distinct(posid[abs(nearestOncoFeatureDist) <= 50000]) / n_distinct(posid)) %>%
  ungroup() %>%
  arrange(percentNearOnco) %>%
  mutate(source = 'WAS') %>%
  data.frame()


# Create a bar plot comparing the percentage of intSites near oncogenes for human subjects vs WAS d0 subjects.
WASvsHumanSubjects <- 
  bind_rows(humanSitesNearOnco, wasSitesNearOnco) %>%
  arrange(percentNearOnco) %>%
  mutate(patient = factor(patient, levels=unique(patient))) %>%
  ggplot(aes(patient, percentNearOnco, fill=source)) +
    theme_bw() +
    scale_fill_manual(values=c('gray75', 'blue')) +
    geom_bar(stat='identity') +
    theme(axis.text.x = element_text(angle = 90, hjust = 1)) +
    guides(fill = FALSE) +
    scale_y_continuous(limits = c(0, 0.33), labels = scales::percent) +
    labs(x='Subject', y='Sites near oncogenes')
    

# Create similiar data frames and plots for the mouse subject by comparing the mouse subjects to a previously 
# published mouse study.

mouseSitesNearOnco <- 
  data.frame(subset(intSites, organism=='mouse')) %>%
  ### filter(patient %in% cellTransfers$From) %>%
  filter(GTSP %in% cellTransfers$From) %>%
  group_by(patient) %>%
  summarise(percentNearOnco = n_distinct(posid[abs(nearestOncoFeatureDist) <= 50000]) / n_distinct(posid)) %>%
  ungroup() %>%
  filter(percentNearOnco > 0) %>%
  arrange(percentNearOnco) %>%
  mutate(source = 'CYS') %>%
  data.frame()


load('data/PMC3129560_mouseTrial/PMC3129560.RData')
PMC3129560.intSiteData$patient <- 'PMC3129560'
PMC3129560.intSiteData <- gt23::addPositionID(PMC3129560.intSiteData)


PMC3129560SitesNearOnco <- 
  data.frame(PMC3129560.intSiteData) %>%
  summarise(patient=patient[1],
            percentNearOnco = n_distinct(posid[abs(nearestOncoFeatureDist) <= 50000]) / n_distinct(posid)) %>%
  filter(percentNearOnco > 0) %>%
  mutate(source = 'PMC3129560') %>%
  data.frame()


PMC3129560vsMouseSubjects <-
  bind_rows(mouseSitesNearOnco, PMC3129560SitesNearOnco) %>%
  arrange(percentNearOnco) %>%
  mutate(patient = factor(patient, levels=unique(patient))) %>%
  ggplot(aes(patient, percentNearOnco, fill=source)) +
  theme_bw() +
  scale_fill_manual(values=c('gray75', 'blue')) +
  geom_bar(stat='identity') +
  theme(axis.text.x = element_text(angle = 90, hjust = 1)) +
  guides(fill = FALSE) +
  scale_y_continuous(limits = c(0, 0.10), labels = scales::percent) +
  labs(x='Subject', y='Sites near oncogenes')


# Create a series of distributions showing the integrations sites vs the number of 
# associated fragments (inferred cells) for the study samples as well as the previously 
# published WAS time points.

prevWASd0IntSiteFrags <- 
  WASintSites_d0 %>%
  data.frame() %>%
  group_by(estAbund, timePoint) %>%
  summarise(source = 'WAS', nSites = n_distinct(posid)) %>%
  ungroup() 

prevWASintSiteFrags <- 
  readRDS('data/prevWASintSites.rds') %>%
  data.frame() %>%
  group_by(estAbund, timePoint) %>%
  summarise(source = 'WAS', nSites = n_distinct(posid)) %>%
  ungroup() 

cysIntSiteFrags <- 
  intSites %>%
  data.frame() %>%
  filter(organism == 'human') %>%
  group_by(estAbund, timePoint) %>%
  summarise(source = 'CYS', nSites = n_distinct(posid)) %>%
  ungroup() 

intSiteFragPlot <-
  rbind(prevWASd0IntSiteFrags, prevWASintSiteFrags, cysIntSiteFrags) %>% 
  filter(timePoint %in% c('d0', 'D14', 'm6', 'm12')) %>%
  mutate('Data set' = toupper(paste(source, timePoint))) %>%
  ggplot(aes(estAbund, log2(nSites+1), fill=`Data set`)) +
    theme_bw() +
    geom_bar(stat='identity') +
    scale_fill_manual(name = 'Data set', values=c('green3', 'dodgerblue', 'gold1', 'red')) +
    xlim(c(1, 100)) +
    labs(x='Clones', y='log2(Number of integration sites + 1)')


# Create intSite heat maps.

# Create a list of chromosome lengths for select chromosomes, ie. [['chr1']] <- 248956422.
library(BSgenome.Hsapiens.UCSC.hg38)
names(intSites)   <- NULL
names(WASintSites_d0) <- NULL
chromosomeLengths <- sapply(rev(paste0("chr", c(seq(1:21), "X", "Y"))),
                            function(x){length(BSgenome.Hsapiens.UCSC.hg38[[x]])},
                            simplify = FALSE, USE.NAMES = TRUE)

humanIntSiteMap <- intSiteDistributionPlot(subset(intSites, organism == 'human'), chromosomeLengths, alpha = 0.025)
WASintSites_d0_map <- intSiteDistributionPlot(WASintSites_d0, chromosomeLengths, alpha = 0.2)


library(BSgenome.Mmusculus.UCSC.mm9)
chromosomeLengths <- sapply(rev(paste0("chr", c(seq(1:19), "X", "Y"))),
                            function(x){length(BSgenome.Mmusculus.UCSC.mm9[[x]])},
                            simplify = FALSE, USE.NAMES = TRUE)

mouseIntSiteMap <- intSiteDistributionPlot(subset(intSites, organism == 'mouse'), chromosomeLengths, alpha = 0.2)
mouseDonorIntSiteMap <- intSiteDistributionPlot(subset(intSites, GTSP %in% cellTransfers$From), chromosomeLengths, alpha = 0.3)
mouseRecipientIntSiteMap <- intSiteDistributionPlot(subset(intSites, GTSP %in% cellTransfers$To), chromosomeLengths, alpha = 0.5)


# Create relative abundance plots for the human samples and store them as a list of grobs so that they 
# can be arranged in the report.

o <-
  intSites %>% 
  data.frame() %>%
  filter(organism == 'human') %>%
  group_by(GTSP) %>%
  mutate(nSites = n_distinct(posid),
         cells  = numShortHand(sum(estAbund)),
         VCN    = paste0('VCN: ', VCN)) %>%
  arrange(desc(relAbund)) %>%
  filter(between(row_number(), 1, 25)) %>%
  select(GTSP, patient, cellType, cells, VCN, relAbund, nearestFeature, posid, nSites) %>%
  do(add_row(.,
             GTSP=.$GTSP[1], 
             patient=.$patient[1], 
             relAbund=100-sum(.$relAbund), 
             nearestFeature='LowAbund', 
             posid='x', 
             nSites=.$nSites[1], 
             .before = 1)) %>%
  ungroup()

humanRelAbundPlots <- 
  lapply(split(o, o$GTSP), function(x){
    x$nearestFeature <- factor(x$nearestFeature, levels = unique(x$nearestFeature))
    
    ggplot(x, aes(GTSP, relAbund/100, fill = nearestFeature)) +
      theme_bw() +
      geom_bar(stat='identity') +
      scale_fill_manual(values = c('gray90', colorRampPalette(brewer.pal(12, "Paired"))(25))) +
      labs(x='', y='') +
      scale_y_continuous(labels = scales::percent) +
      theme(legend.position="none") +
      ggtitle(paste0(x$patient[1], '\n', x$cellType[nrow(x)], '\n', ppNum(x$nSites[1]), ' sites in ', 
                     x$cells[2], ' cells\n', x$VCN[nrow(x)])) +
      theme(plot.title = element_text(size = 6.5)) +
      theme(plot.margin = unit(c(0,0,0,0), "cm")) + 
      theme(panel.border = element_blank(), panel.grid.major = element_blank(),
            panel.grid.minor = element_blank(), axis.line = element_line(colour = "black"))
  })

rm(o)


# Create a table of clones that exceeded 20% relative abundance.
abundantClones20 <-
  intSites %>%
  data.frame() %>%
  select(patient, organism, timePoint, cellType, posid, relAbund, estAbund, nearestFeature) %>%
  filter(relAbund > 20) %>%
  arrange(organism) %>%
  mutate(relAbund = sprintf("%.02f%%", relAbund))


# Create a sample summary of all analyzed samples.
sampleSummary <-
  intSites %>%
  data.frame() %>%
  select(patient, GTSP, organism, timePoint, cellType, posid, relAbund, estAbund, nearestFeature, VCN) %>%
  group_by(organism, GTSP) %>%
  summarise(Subject = patient[1],
            'Cell type' = cellType[1],
            'VCN' = VCN[1],
            'Time point' = timePoint[1],
            'Number inferred cells' = ppNum(sum(estAbund)),
            'Number of intSites' = ppNum(length(unique(posid)))) %>%
  ungroup()
  
  
# Currently the returned intSite object contains 'TRUE' or NA -- NA breaks ifelse.
intSites$inFeature[is.na(intSites$inFeature)] <- 'FALSE'

intSites$nearestFeature2 <- 
  intSites %>%
  data.frame() %>%
  mutate(nearestFeature2 = paste0(nearestFeature, ' ')) %>% 
  mutate(nearestFeature2 = ifelse(inFeature == 'TRUE', paste0(nearestFeature2, '*'), nearestFeature2)) %>%
  mutate(nearestFeature2 = ifelse(abs(nearestOncoFeatureDist) <= 50000, paste0(nearestFeature2, '~'), nearestFeature2)) %>%
  select(nearestFeature2) %>%
  unlist() %>%
  unname()


# Cycle through the cell transplant trials and create relative abunance plots, matrix of intSites
# near oncogenes, and data frames of intSites that persist in the recipient mice.

emptyRecipientPlotLabels <- list('pCN671' = 'pCN748\n(no sites)', 'pMouseCNL25group4' = 'pCNL59\n(no sites)')

transferTrials <- lapply(1:nrow(cellTransfers), function(i){
  d <- cellTransfers[i,]
  
  a <- data.frame(subset(intSites, GTSP == d$From))
  b <- data.frame(subset(intSites, GTSP == d$To))
  
  createPlotData <- function(x){
    arrange(x, desc(relAbund)) %>%
    mutate(label1 = paste0(x$patient[1], '\n',
                          'VCN: ', VCN[1], '\n',
                          'Unique sites: ', ppNum(length(unique(posid))), '\n',
                          'Inferred cells: ', numShortHand(sum(estAbund)), '\n',
                          x$timePoint[1], ' / ', x$cellType[1])) %>%
    mutate(label2 = paste0(nearestFeature2, '\n', posid)) %>%
    filter(between(row_number(), 1, 12)) %>%
    select(label1, label2, relAbund) %>%
    add_row(relAbund=100-sum(.$relAbund),
            label1 = .$label1[1],
            label2 = 'LowAbund',
            .before = 1)
  }
  
  plotData <- bind_rows(createPlotData(a), createPlotData(b))
  
  if(a$patient[1] %in% names(emptyRecipientPlotLabels) & length(which(is.na(plotData$label1))) > 0){
    plotData[which(is.na(plotData$label1)),]$label1 <- emptyRecipientPlotLabels[[a$patient[1]]]
  }
  
  plot <- 
    plotData %>%
    mutate(label1 = factor(label1, levels=unique(label1))) %>%
    mutate(label2 = factor(label2, levels = unique(label2))) %>%
    mutate(label2 = fct_relevel(label2, 'LowAbund')) %>%
    arrange(desc(relAbund)) %>%
    ggplot(aes(label1, relAbund/100, fill=label2)) +
      theme_bw() +
      geom_bar(stat='identity') +
      scale_fill_manual(name = 'Integrations', values = c('gray90', createColorPalette(24))) +
      scale_y_continuous(labels = scales::percent_format(accuracy = 1)) +
      labs(x='', y='Relative abundance') +
    guides(fill=guide_legend(ncol=2)) +
    theme(legend.key.size = unit(2, "line"), legend.text=element_text(size=10)) +
    theme(panel.border = element_blank(), panel.grid.major = element_blank(),
          panel.grid.minor = element_blank(), axis.line = element_line(colour = "black"))
  
  
  m <- matrix(c(sum(abs(a$nearestOncoFeatureDist) > 50000, na.rm = TRUE),  sum(abs(a$nearestOncoFeatureDist) <= 50000, na.rm = TRUE),
                sum(abs(b$nearestOncoFeatureDist) > 50000, na.rm = TRUE),  sum(abs(b$nearestOncoFeatureDist) <= 50000, na.rm = TRUE)), 
              byrow = TRUE, 
              nrow = 2,
              dimnames = list(c(a$patient[1], b$patient[1]), c('Not near onco', 'Near onco')))

  
  sharedSites <- bind_rows(lapply(b$posid[unique(b$posid) %in% unique(a$posid)], function(posID){
    data.frame(Donor = a$patient[1],
               Recipient = b$patient[1],
               intSite = posID,
               'Donor cells' = ppNum(sum(subset(a, posid == posID)$estAbund)),
               'Recipient cells' = ppNum(sum(subset(b, posid == posID)$estAbund)),
               check.names = FALSE) }))
  
  list(plot = plot, m = m, sharedSites = sharedSites)
})


# Assemble the intSite persistence table
cellTransfer_intSites_table <- bind_rows(lapply(transferTrials, '[[', 3))


# Create UCSC track files.

dplyr::group_by(data.frame(subset(intSites, organism == 'human')), posid) %>%
  dplyr::arrange(desc(estAbund)) %>%
  dplyr::slice(1) %>%
  dplyr::mutate(siteLabel = paste0(patient, '_', posid)) %>%
  dplyr::ungroup() %>%
  createUCSCintSiteTrack(title = 'CYS_mouse', outputFile = 'UCSC_CYS_human.group1.ucsc', siteLabel = 'siteLabel', padSite = 5)
system(paste0('scp UCSC_CYS_human.group1.ucsc  microb120:/usr/share/nginx/html/UCSC/cherqui/'))
invisible(file.remove('UCSC_CYS_human.group1.ucsc'))


dplyr::group_by(data.frame(subset(intSites, organism == 'mouse')), posid) %>%
  dplyr::arrange(desc(estAbund)) %>%
  dplyr::slice(1) %>%
  dplyr::mutate(siteLabel = paste0(patient, '_', posid)) %>%
  dplyr::ungroup() %>%
  createUCSCintSiteTrack(title = 'CYS_mouse', outputFile = 'UCSC_CYS_mouse.group1.ucsc', siteLabel = 'siteLabel', padSite = 5)
system(paste0('scp UCSC_CYS_mouse.group1.ucsc  microb120:/usr/share/nginx/html/UCSC/cherqui/'))
invisible(file.remove('UCSC_CYS_mouse.group1.ucsc'))


# Report shortcuts.
humanGenomePercentOnco <- round((n_distinct(toupper(gt23::hg38.oncoGeneList)) / n_distinct(toupper(gt23::hg38.refSeqGenesGRanges$name2)))*100, digits=2)
mouseGenomePercentOnco <- round((n_distinct(toupper(gt23::mm9.oncoGeneList)) / n_distinct(toupper(gt23::mm9.refSeqGenesGRanges$name2)))*100, digits=2)


# Save data for report generation.
save.image(file='project.group1.RData')

