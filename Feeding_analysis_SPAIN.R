###########################################################################################################################
###### DATA ANALYSIS TO IDENTIFY ANTHROPOGENIC FEEDING SITES OF RED KITES BASED ON GPS TRACKING DATA ################
###########################################################################################################################
# original idea by Nathalie Heiniger (MSc thesis 2020)
# uses csv table prepared by "Feeding_data_prep.r"
# created by steffen.oppel@vogelwarte.ch in June 2023
# ONLY PREDICTION TO SPANISH DATA - no model fitting

library(tidyverse)
library(dplyr, warn.conflicts = FALSE)
options(dplyr.summarise.inform = FALSE)
library(ranger)
library(caret)
library(randomForest)
library(sf)
library(lubridate)
library(leaflet)
library(adehabitatHR)
library(stars)
filter<-dplyr::filter
sf_use_s2(FALSE)
library(pROC)
library(rworldmap)
ESP<-st_as_sf(rworldmap::countriesLow) %>%
  filter(SOVEREIGNT %in% c("Portugal","Spain")) %>%
  st_cast("POLYGON")  %>%
  st_transform(5635) %>%
  mutate(Area=as.numeric(st_area(.))) %>%
  filter(Area>10000000000)   ### removes all the islands
plot(ESP)
# SUI<-st_read("C:/Users/sop/OneDrive - Vogelwarte/General/DATA/SUISSE/ch_1km.shp")


## set root folder for project
setwd("C:/Users/sop/OneDrive - Vogelwarte/REKI/Analysis/REKIfeeding")

# LOADING DATA -----------------------------------------------------------------
### LOAD THE TRACKING DATA AND INDIVIDUAL SEASON SUMMARIES 
track_sf<-readRDS(file = "data/REKI_trackingdata_Spain.rds") %>%
  st_transform(5635)

### READ IN SHAPEFILES OF RUBBISH DUMPS
## add layers that Jaume sent and from 

dumps <- st_read("data/Spain/Vertederos.shp") %>% 
  st_drop_geometry() %>%   ## for some reason the CRS is weird and wrong
  st_as_sf(coords = c("LONGITUD", "LATITUD"))
st_crs(dumps) <- 4326


# CREATING BASELINE MAP OF POINT DENSITY IN SPAIN -----------------------------------------------------------------

grid <- ESP %>%
  st_make_grid(cellsize = 5000, what = "polygons",  ## increased from 500 to 5000 to manage computation
               square = FALSE) # This statements leads to hexagons

ESPgrid <-grid[lengths(st_intersects(grid,ESP))==1]
sum(st_area(ESPgrid))/1000000  ## size of study area in sq km

tab <- st_intersects(ESPgrid, track_sf)
lengths(tab)
countgrid <- st_sf(n=lengths(tab), geometry = st_cast(ESPgrid, "MULTIPOLYGON")) %>%
  st_transform(5635)
summary(log(countgrid$n+1))
pal <- colorNumeric(c("cornflowerblue","firebrick"), seq(0,10.5))


leaflet(options = leafletOptions(zoomControl = F)) %>% #changes position of zoom symbol
  htmlwidgets::onRender("function(el, x) {L.control.zoom({ 
                           position: 'bottomright' }).addTo(this)}"
  ) %>% #Esri.WorldTopoMap #Stamen.Terrain #OpenTopoMap #Esri.WorldImagery
  addProviderTiles("Esri.WorldImagery", group = "Satellite",
                   options = providerTileOptions(opacity = 0.6, attribution = F)) %>%
  addProviderTiles("OpenTopoMap", group = "Roadmap", options = providerTileOptions(attribution = F)) %>%  
  addLayersControl(baseGroups = c("Satellite", "Roadmap")) %>%  
  
  addPolygons(
    data=countgrid %>%
      st_transform(4326),
    stroke = TRUE, color = ~pal(log(n+1)), weight = 1,
    fillColor = ~pal(log(n+1)), fillOpacity = 0.5
  ) %>%
  
  addPolylines(
    data=ESP %>%
      st_transform(4326),
    stroke = TRUE, color = "black", weight = 1.5
  ) %>%
  
  addCircleMarkers(
    data=dumps,
    radius = 3,
    stroke = TRUE, color = "green", weight = 0.8,
    fillColor = "green", fillOpacity = 0.8
  ) %>%
  
  addScaleBar(position = "bottomright", options = scaleBarOptions(imperial = F))

#### basic numbers of Spanish grid
length(ESPgrid)
dim(countgrid[countgrid$n>20,])[1]/length(ESPgrid)


##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
########## APPLYING RANDOM FOREST MODEL TO SPANISH DATA        #############
##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
RF2<-readRDS("output/feed_site_RF_model.rds")


################ TAKE SUBSET OF DATA AND PREPARE DATA FOR PREDICTION#######################

DATA <- track_sf %>% dplyr::filter(tod_=="day") %>%
  dplyr::mutate(longitude = sf::st_coordinates(.)[,1],
                latitude = sf::st_coordinates(.)[,2]) %>%
  st_drop_geometry() %>%
  mutate(YDAY=yday(t_), hour=hour(t_), month=month(t_)) %>%
  filter(!is.na(step_length)) %>%
  filter(!is.na(turning_angle)) %>%
  filter(!is.na(speed)) %>%
  filter(!is.na(mean_speed)) %>%
  filter(!is.na(mean_angle)) %>%
  select(-tod_) %>%
  mutate(BUILD=1, NEST=0, dist_nest=100000) %>%
  mutate(point_id=seq_along(t_))
head(DATA)
str(DATA)


### PREDICT FORAGING BEHAVIOUR ###
PRED<-stats::predict(RF2,data=DATA, type = "response")

DATA <- DATA %>%
  dplyr::bind_cols(PRED$predictions) %>%
  dplyr::rename(no_feed_prob = NO, feed_prob = YES) %>%
  dplyr::mutate(FEEDER_predicted = as.factor(dplyr::case_when(feed_prob > 0.15 ~ "YES",   ### prevalence as estimated by Feeding_analysis.r
                                                              feed_prob < 0.15 ~ "NO")))
  # dplyr::mutate(FEEDER_predicted = as.factor(dplyr::case_when(feed_prob > 0.02367809 ~ "YES",   ### prevalence as estimated by Feeding_analysis.r
  #                                                             feed_prob < 0.02367809 ~ "NO")))




##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
########## SECOND LEVEL PREDICTION: COUNT POINTS AND INDIVIDUALS IN GRID   #############
##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################

#### FIRST COUNT N INDIVIDUALS PER GRID CELL

for(c in 1:length(tab)){
  countgrid$N_ind[c]<-length(unique(track_sf$year_id[tab[c][[1]]]))
}

#### SECOND COUNT N INDIVIDUALS AND PREDICTED FEEDING LOCS PER GRID CELL
OUT_sf<-DATA %>%
  filter(FEEDER_predicted=="YES") %>%
  st_as_sf(coords = c("long", "lat"), crs = 4326) %>%
  st_transform(5635)
tab2 <- st_intersects(ESPgrid, OUT_sf)
countgrid$N_feed_points<-lengths(tab2)
for(c in 1:length(tab2)){
  countgrid$N_feed_ind[c]<-length(unique(OUT_sf$year_id[tab2[c][[1]]]))
}

### MANIPULATE COUNTED ANIMALS INTO PROPORTIONS

countgrid<-countgrid %>%
  mutate(prop_feed=N_feed_ind/N_ind) %>%
  mutate(prop_pts=N_feed_points/n)


### overlay feeder data with countgrid
feed_grd<-st_intersects(countgrid,(dumps %>% st_transform(5635)))
countgrid$FEEDER<-lengths(feed_grd) 


PRED_GRID<-countgrid %>% 
  mutate(gridid=seq_along(n)) %>%
  filter(n>20) %>%
  st_drop_geometry() %>%
  mutate(FEEDER=ifelse(FEEDER==0,0,1))

RF3<-readRDS("output/feed_grid_RF_model.rds")
PRED<-stats::predict(RF3,data=PRED_GRID, type = "response")
PRED_GRID <- PRED_GRID %>%
  dplyr::mutate(FEEDER_observed = FEEDER) %>%
  dplyr::mutate(FEEDER_predicted=PRED$predictions[,2])
dim(PRED$predictions)
dim(PRED_GRID)

ROC_Spain<-pROC::roc(data=PRED_GRID,response=FEEDER_observed,predictor=FEEDER_predicted)
AUC<-pROC::auc(ROC_Spain)
AUC
THRESH<-pROC::coords(ROC_Spain, "best", "threshold")$threshold


########## CREATE OUTPUT GRID WITH PREDICTED FEEDING LOCATIONS ########################

OUTgrid<-countgrid %>% select(-FEEDER) %>%
  mutate(gridid=seq_along(n)) %>%
  left_join(PRED_GRID, by=c("gridid","n","N_ind","N_feed_points","N_feed_ind","prop_feed","prop_pts")) %>%
  filter(!is.na(FEEDER_predicted))




##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
########## PLOT THE MAP FOR PREDICTED FOOD SUBSIDY ACROSS SPAIN   #############
##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################

########## CREATE A LEAFLET MAP OF PREDICTED FEEDING LOCATIONS ########################

## need to specify color palette 
# If you want to set your own colors manually:
pred.pal <- colorNumeric(c("cornflowerblue","firebrick"), seq(0,1))
m2 <- leaflet(options = leafletOptions(zoomControl = F)) %>% #changes position of zoom symbol
  setView(lng = mean(st_coordinates(dumps)[,1]), lat = mean(st_coordinates(dumps)[,2]), zoom = 7) %>%
  htmlwidgets::onRender("function(el, x) {L.control.zoom({ 
                           position: 'bottomright' }).addTo(this)}"
  ) %>% #Esri.WorldTopoMap #Stamen.Terrain #OpenTopoMap #Esri.WorldImagery
  addProviderTiles("Esri.WorldImagery", group = "Satellite",
                   options = providerTileOptions(opacity = 0.2, attribution = F,minZoom = 5, maxZoom = 20)) %>%
  addProviderTiles("OpenTopoMap", group = "Roadmap", options = providerTileOptions(attribution = F,minZoom = 5, maxZoom = 15)) %>%  
  addLayersControl(baseGroups = c("Satellite", "Roadmap")) %>%  
  
  addPolygons(
    data=OUTgrid %>%
      st_transform(4326),
    stroke = TRUE, color = ~pred.pal(FEEDER_predicted), weight = 1,
    fillColor = ~pred.pal(FEEDER_predicted), fillOpacity = 0.5,
    popup = ~as.character(paste("N_pts=",n,"/ N_ind=",N_ind,"/ Prop feed pts=",round(prop_feed,3), sep=" ")),
    label = ~as.character(round(FEEDER_predicted,3))
  ) %>%
  
  addCircleMarkers(
    data=dumps %>%
      st_transform(4326),
    radius = 2,
    stroke = TRUE, color = "green", weight = 1,   ###~feed.pal(Type)
    fillColor = "green", fillOpacity = 0.5   ## ~feed.pal(Type)
  ) %>%
  
  addPolylines(
    data=ESP %>%
      st_transform(4326),
    stroke = TRUE, color = "black", weight = 1.5
  ) %>%
  
  addLegend(     # legend for predicted prob of feeding
    position = "topleft",
    pal = pred.pal,
    values = OUTgrid$FEEDER_predicted,
    opacity = 1,
    title = "Predicted probability of </br>anthropogenic feeding"
  ) %>%
  
  
  addScaleBar(position = "bottomright", options = scaleBarOptions(imperial = F))

m2


htmltools::save_html(html = m2, file = "C:/Users/sop/OneDrive - Vogelwarte/REKI/Analysis/REKIfeeding/output/REKI_predicted_anthropogenic_feeding_areas_SPAIN.html")
mapview::mapshot(m2, url = "C:/Users/sop/OneDrive - Vogelwarte/REKI/Analysis/REKIfeeding/output/REKI_predicted_anthropogenic_feeding_areas_SPAIN.html")
st_write(OUTgrid,"output/REKI_predicted_anthropogenic_feeding_areas_SPAIN.kml",append=FALSE)




##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
########## SIMPLE NUMBERS FOR MANUSCRIPT  #############
##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################


dim(OUTgrid[OUTgrid$FEEDER_predicted>0.15,])
dim(OUTgrid[OUTgrid$FEEDER_predicted>0.15,])/dim(OUTgrid)


##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
########## VALIDATE PREDICTIONS WITH INDEPENDENT RUBBISH DUMP DATA  #############
##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
dumps <- dumps %>%
  st_transform(5635)
validat <- st_intersection(dumps,OUTgrid) %>%
  filter(!is.na(n))  ## excludes grids with no tracking data
summary(validat$FEEDER_predicted)


##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
########## SUMMARISE VALIDATION DATA  #############
##########~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~######################################
VAL_DAT<-validat %>%
  select(n,N_ind,N_feed_points,N_feed_ind,prop_feed,prop_pts,FEEDER_predicted) %>%
  mutate(Classification=ifelse(FEEDER_predicted>THRESH,"correct","missed"))

### summarise the predicted sites
table(VAL_DAT$Classification)[1]
summary(VAL_DAT$FEEDER_predicted)
mean(VAL_DAT$FEEDER_predicted)
table(VAL_DAT$Classification)[1]/dim(VAL_DAT)[1]
min(VAL_DAT$n[VAL_DAT$Classification=="correct"])
min(VAL_DAT$N_ind[VAL_DAT$Classification=="correct"])
min(VAL_DAT$N_feed_points[VAL_DAT$Classification=="correct"])
min(VAL_DAT$N_feed_ind[VAL_DAT$Classification=="correct"])








