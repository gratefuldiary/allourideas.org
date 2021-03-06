Feature: Different api users
  In order to keep the AOI and Photocracy API data separated
  Requests made to Photocracy should result in different credentials being sent to the API
    
    @photocracy
    Scenario: User votes on a photocracy page
      Given a photocracy idea marketplace quickly exists with url 'princeton'
      When I go to the Cast Votes page for 'princeton'
