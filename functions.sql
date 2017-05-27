-- Reserver un billet et returner le id de reservation
CREATE OR REPLACE FUNCTION reserver (idRepre INTEGER, numbre INTEGER) RETURNS INTEGER AS $$
DECLARE
  vendu numeric (8,2);
  reserve numeric (8,2);
  capacity numeric (8,2);
  now Today.time%TYPE;
  idgenerated INTEGER;
BEGIN
  SELECT time INTO now FROM Today WHERE id = 0;          
  SELECT places INTO capacity FROM Repre_Interne AS R NATURAL JOIN Spectacle AS S WHERE R.id_repre = idRepre;
  SELECT * INTO vendu FROM calc_numbre_place_dans_billet(idRepre);
  SELECT * INTO reserve FROM calc_numbre_place_dans_reserv(idRepre);
  -- TODO remove place check and auto calculate date_delai )
  WITH ROWS AS ( INSERT INTO Reservation (id_repre, date_reserver, date_delai, numbre_reserver) 
                          VALUES (idRepre, now, now + interval '72 hours', numbre) RETURNING id_reserve )
  SELECT INTO idgenerated (SELECT id_reserve FROM ROWS);
  RETURN idgenerated;
END;
$$ LANGUAGE plpgsql;

-----------------------

CREATE OR REPLACE FUNCTION calc_numbre_place_dans_billet (idRepre INTEGER) RETURNS INTEGER AS $$
DECLARE
  placeVendu INTEGER;
BEGIN
  SELECT COALESCE(sum(numbre), 0) INTO placeVendu FROM Billet WHERE id_repre = idRepre;
  raise notice 'Places vendus : % ', placeVendu;	
  RETURN placeVendu;
END;
$$ LANGUAGE plpgsql;

------------------------

CREATE OR REPLACE FUNCTION calc_numbre_place_dans_reserv (idRepre INTEGER) RETURNS INTEGER AS $$
DECLARE
  placeReserve INTEGER;
BEGIN
  SELECT COALESCE(sum(numbre_reserver), 0) INTO placeReserve FROM Reservation WHERE id_repre = idRepre;
  raise notice 'Places reserves : % ', placeReserve;
  RETURN placeReserve;
END;
$$ LANGUAGE plpgsql;

------------------------

CREATE OR REPLACE FUNCTION get_seat_sold_percentage (idRepre INTEGER) RETURNS numeric (2,2) AS $$
DECLARE
  vendu numeric (8,2);
  capacity numeric (8,2);
BEGIN
          SELECT places INTO capacity FROM Repre_Interne AS R NATURAL JOIN Spectacle AS S WHERE R.id_repre = idRepre;
          SELECT * INTO vendu FROM calc_numbre_place_dans_billet(idRepre);
          raise notice 'Taux de vente : % ', vendu/capacity;
          RETURN vendu/capacity;
END;
$$ LANGUAGE plpgsql;

------------------------

CREATE OR REPLACE FUNCTION get_seat_full_percentage (idRepre INTEGER) RETURNS numeric (2,2) AS $$
DECLARE
  vendu numeric (8,2);
  reserve numeric (8,2);
  capacity numeric (8,2);
BEGIN
	  SELECT places INTO capacity FROM Repre_Interne AS R NATURAL JOIN Spectacle AS S WHERE R.id_repre = idRepre;
	  SELECT * INTO vendu FROM calc_numbre_place_dans_billet(idRepre);
	  SELECT * INTO reserve FROM calc_numbre_place_dans_reserv(idRepre);
	  raise notice 'Taux de remplissage : % ', (vendu+reserve)/capacity;
	  RETURN (vendu+reserve)/capacity;
END;
$$ LANGUAGE plpgsql;

------------------------

CREATE OR REPLACE FUNCTION get_current_ticket_price (idRepre INTEGER, tarifType INTEGER) RETURNS numeric (8,2) AS $$
DECLARE
  jointInfo record;
  prixOrigin numeric (8,2);
  prix numeric (8,2);
  delta numeric (8,2);
  today Today.time%TYPE;
BEGIN
  SELECT time INTO today FROM Today WHERE id = 0;
  SELECT * INTO jointInfo FROM (Repre_Interne AS R NATURAL JOIN Spectacle AS S) WHERE R.id_repre = idRepre;
  CASE tarifType /* 0=Normal, 1=Reduit*/
  WHEN 1 THEN
        prixOrigin := jointInfo.tarif_reduit;
  WHEN 0 THEN
        prixOrigin := jointInfo.tarif_normal;
  END CASE;
  prix := prixOrigin;
  CASE jointInfo.politique
  WHEN 1 THEN /* 20% reduction pour le premier 5 jours de commerce */
        /* PostgreSQL accepts two equivalent syntaxes for type casts, the PostgreSQL-specific value::type and the SQL-standard CAST(value AS type). */
        SELECT into delta EXTRACT(epoch FROM (today - jointInfo.date_prevendre))::integer/3600;
        IF (delta < 120 AND delta > 0) THEN /* 120 = 5 jours * 24 heures */
          prix := prixOrigin * 0.8;
        END IF;
  WHEN 2 THEN /*  */
	SELECT into delta EXTRACT(epoch FROM (jointInfo.date_sortir - today))::integer/3600;
	IF (delta < 360 AND delta > 0 ) THEN /* 360 = 15 jours * 24 heures */
	  SELECT * INTO delta FROM get_seat_full_percentage(idRepre);
          IF (delta < 0.3) THEN
            prix := prixOrigin * 0.5;
          ELSIF (delta < 0.5) THEN
            prix := prixOrigin * 0.7;
          END IF;
	END IF;
  WHEN 3 THEN /* 30% reduction pour le premier 30% des billets*/
        SELECT * INTO delta FROM get_seat_sold_percentage(idRepre);
        IF (delta < 0.3) THEN /* 360 = 15 jours * 24 heures */
          prix := prixOrigin * 0.7;
        END IF;
  END CASE;
  RETURN prix;
END;      
$$ LANGUAGE plpgsql;

------------------------

CREATE OR REPLACE FUNCTION payReservation ( myIdReserve INTEGER, numbre_tarifNormal INTEGER, numbre_tarifReduit INTEGER) RETURNS void AS $$
DECLARE
  reserveInfo Reservation%ROWTYPE;
BEGIN
  select * into reserveInfo from Reservation where id_reserve = myIdReserve;
  
  IF NOT FOUND then
  raise notice 'La Reservation n existe pas';
  return;
  END IF;

  IF (numbre_tarifReduit+numbre_tarifNormal <> reserveInfo.numbre_reserver) THEN
  raise notice 'numbre de reserve est incorrect';
  return;
  END IF;

  Delete from Reservation where id_reserve = myIdReserve;

  IF(numbre_tarifNormal = 0) then
  INSERT INTO Billet (id_repre, tarif_type, prix_effectif, numbre) VALUES
  (reserveInfo.id_repre, 1, 0, numbre_tarifReduit);
  raise notice 'acheter % billets en tarif_reduit', numbre_tarifReduit;
  
  ELSIF(numbre_tarifNormal = 0) then
  INSERT INTO Billet (id_repre, tarif_type, prix_effectif, numbre) VALUES
  (reserveInfo.id_repre, 0, 0, numbre_tarifNormal);
  raise notice 'acheter % billets en tarif_normal', numbre_tarifNormal;
  
  ELSE
  INSERT INTO Billet (id_repre, tarif_type, prix_effectif, numbre) VALUES
  (reserveInfo.id_repre, 0, 0, numbre_tarifNormal),
  (reserveInfo.id_repre, 1, 0, numbre_tarifReduit);
  raise notice 'acheter % billets en tarif_normal, % billets en tarif_reduit', numbre_tarifNormal, numbre_tarifReduit;

  return;
  END IF;
  
END
$$ LANGUAGE plpgsql;
